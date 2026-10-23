import Link from 'next/link';
import { notFound } from 'next/navigation';
import { PageHead } from '@/components/Blocks';
import { JsonLd } from '@/components/JsonLd';
import { breadcrumbLd, seoMeta, type Trail } from '@/features/seo/meta';
import { rpc } from '@/lib/db/repo';
import { getSettings } from '@/lib/site';

// The place directory (migration 0115): every place with pages, a thousand a page in the database's own order (a
// primary key range: one cheap read a page), so any place page is three clicks from the home page (footer Browse,
// this index, a page of it) and any of its term pages four. Plain links only. Rendered on demand (no build-time read).
export const dynamic = 'force-dynamic';
type Params = { params: Promise<{ page?: string[] }> };
type IndexRow = { page: number; places: number; regions: string[]; first: string | null; last: string | null };
type PlaceRow = { slug: string; name: string; kind: string; country: string; region: string | null; region_name: string | null; parent: string | null };

const KIND: Record<string, string> = { country: 'Countries', province: 'Provinces and states', region: 'Regions and counties', area: 'Areas', city: 'Cities and towns', neighbourhood: 'Neighbourhoods', airport: 'Airports' };
const pageNo = (seg: string[] | undefined) => { if (!seg?.length) return 0; if (seg.length !== 1 || !/^[1-9]\d{0,5}$/.test(seg[0]!)) return -1; return Number(seg[0]); };

export async function generateMetadata({ params }: Params) {
  const n = pageNo((await params).page);
  if (n < 0) notFound();
  return n === 0
    ? seoMeta({ title: 'Every Place We Cover | CarmaCars', path: '/places', description: 'Every city, town, neighbourhood and airport with a CarmaCars page in Canada, the United States and Mexico, by region.' })
    : seoMeta({ title: `Places, Page ${n} | CarmaCars`, path: `/places/${n}`, description: `Cities, towns, neighbourhoods and airports with a CarmaCars page: page ${n} of the place directory.` });
}

export default async function Places({ params }: Params) {
  const n = pageNo((await params).page);
  if (n < 0) notFound();
  const s = await getSettings();
  if (n === 0) {
    const pages = ((await rpc('place_directory_index', {})) ?? []) as unknown as IndexRow[];
    const trail: Trail = [['Home', '/'], ['Places']];
    const byRegion = new Map<string, IndexRow[]>();
    for (const p of pages) for (const r of p.regions.slice(0, 3)) (byRegion.get(r) ?? byRegion.set(r, []).get(r)!).push(p);
    return (
      <div className="p-legal" data-page="place-directory">
        <JsonLd graph={[breadcrumbLd(trail, '/places')]} />
        <PageHead trail={trail} h1="Every place we cover" lead={`Every place with a ${s.brand_name} page, a thousand to a page. A place page never means we have a location there: we have one, in Toronto, and deliver around it.`} />
        <section className="section"><div className="wrap stack">
          {pages.length === 0 && <p className="muted">No places are loaded yet.</p>}
          <nav aria-label="Place directory pages"><ul className="linklist" data-testid="directory-pages">
            {pages.map((p) => <li key={p.page}><Link prefetch={false} className="link" href={`/places/${p.page}`}>Page {p.page}: {p.regions.slice(0, 3).join(', ')}{p.regions.length > 3 ? ' and more' : ''} ({p.places.toLocaleString('en-CA')} places, {p.first} to {p.last})</Link></li>)}
          </ul></nav>
          <p><Link prefetch={false} className="link" href="/car-rental">Car rental by place</Link> · <Link prefetch={false} className="link" href="/makes">Every make and model</Link></p>
        </div></section>
      </div>
    );
  }
  const [rowsR, idxR] = await Promise.all([rpc('place_directory_page', { p_page: n }), rpc('place_directory_index', {})]);
  const rows = (rowsR ?? null) as unknown as PlaceRow[] | null;
  if (!rows || rows.length === 0) notFound();
  const nums = ((idxR ?? []) as unknown as IndexRow[]).map((x) => x.page);
  const prev = nums.filter((x) => x < n).pop(), next = nums.find((x) => x > n);
  const trail: Trail = [['Home', '/'], ['Places', '/places'], [`Page ${n}`]];
  const groups = new Map<string, PlaceRow[]>();
  for (const r of rows) { const k = `${r.region_name ?? r.country}|${r.kind}`; (groups.get(k) ?? groups.set(k, []).get(k)!).push(r); }
  return (
    <div className="p-legal" data-page="place-directory-page">
      <JsonLd graph={[breadcrumbLd(trail, `/places/${n}`)]} />
      <PageHead trail={trail} h1={`Places, page ${n}`} lead="Each place has its own car rental page, with links to its detailing, body shop and buying help pages." />
      <section className="section"><div className="wrap stack-lg">
        {[...groups].map(([k, list]) => { const [region, kind] = k.split('|'); return (
          <section key={k} className="stack" aria-label={`${KIND[kind!] ?? kind} in ${region}`}><h2 className="d4">{KIND[kind!] ?? kind}, {region}</h2>
            <ul className="chips">{list.map((r) => <li key={r.slug}><Link prefetch={false} className="chip" href={`/car-rental/${r.slug}`}>{r.name}{r.parent && r.kind === 'neighbourhood' ? `, ${r.parent}` : ''}</Link></li>)}</ul></section>); })}
        <nav aria-label="More pages" className="row">
          {prev && <Link prefetch={false} className="link" href={`/places/${prev}`} rel="prev">Page {prev}</Link>}
          <Link prefetch={false} className="link" href="/places">Every page</Link>
          {next && <Link prefetch={false} className="link" href={`/places/${next}`} rel="next">Page {next}</Link>}
        </nav>
      </div></section>
    </div>
  );
}
