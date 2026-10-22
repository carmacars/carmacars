import Link from 'next/link';
import { getSeoLinks } from './data';
import '@/styles/seo.css';

// Links from the car pages and the model pages to the ways of renting and the areas we deliver to (0095), with
// descriptive words: the landing pages that may be indexed, Toronto first.
export async function RentMore({ city = 'Toronto', exclude }: { city?: string; exclude?: string }) {
  const links = (await getSeoLinks().catch(() => [])).filter((l) => l.slug !== exclude);
  const uses = links.filter((l) => l.kind === 'use').slice(0, 8);
  const places = links.filter((l) => l.kind === 'location').slice(0, 8);
  if (!uses.length && !places.length) return null;
  return (
    <section className="section--tight" aria-labelledby="h-rentmore" data-testid="rent-more">
      <div className="wrap stack">
        <h2 className="d3" id="h-rentmore">More car rental in {city}</h2>
        <div className="landing__cols">
          {uses.length > 0 && <nav aria-label="Ways to rent"><ul className="linklist">{uses.map((l) => <li key={l.slug}><Link prefetch={false} className="link" href={l.path}>{l.name} in {city}</Link></li>)}</ul></nav>}
          {places.length > 0 && <nav aria-label="Areas we deliver to"><ul className="linklist">{places.map((l) => <li key={l.slug}><Link prefetch={false} className="link" href={l.path}>Car rental in {l.name}</Link></li>)}</ul></nav>}
        </div>
      </div>
    </section>
  );
}
