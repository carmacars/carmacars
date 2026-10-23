import Link from 'next/link';
import { PageHead } from '@/components/Blocks';
import { JsonLd } from '@/components/JsonLd';
import { breadcrumbLd, seoMeta, type Trail } from '@/features/seo/meta';
import { rpc } from '@/lib/db/repo';

// Every make with every model (migration 0115): a model page is two clicks from the home page (footer Browse, this
// page), its years three and their trims four. Plain links; one read of the catalog's makes and models.
export const dynamic = 'force-dynamic';
type Make = { slug: string; name: string; models: Array<{ slug: string; name: string }> };
const trail: Trail = [['Home', '/'], ['Makes and models']];

export async function generateMetadata() {
  return seoMeta({ title: 'Every Make and Model | CarmaCars', path: '/makes',
    description: 'Every car make and model in our catalog: fuel use, dimensions, recalls and complaints by year and trim, and the cars we rent.' });
}
export default async function Makes() {
  const makes = ((await rpc('vehicle_make_index', {})) ?? []) as unknown as Make[];
  return (
    <div className="p-legal" data-page="make-index">
      <JsonLd graph={[breadcrumbLd(trail, '/makes')]} />
      <PageHead trail={trail} h1="Every make and model" lead="Each model has a page for every year and Canadian trim, with the figures from public sources and the cars we rent." />
      <section className="section"><div className="wrap stack-lg">
        {makes.length === 0 && <p className="muted">The catalog is not loaded yet.</p>}
        {makes.map((m) => (
          <section key={m.slug} className="stack" aria-labelledby={`mk-${m.slug}`}>
            <h2 className="d4" id={`mk-${m.slug}`}><Link prefetch={false} className="link" href={`/cars/${m.slug}`}>{m.name}</Link></h2>
            {m.models.length > 0 && <ul className="chips">{m.models.map((x) => <li key={x.slug}><Link prefetch={false} className="chip" href={`/cars/${m.slug}/${x.slug}`}>{m.name} {x.name}</Link></li>)}</ul>}
          </section>
        ))}
      </div></section>
    </div>
  );
}
