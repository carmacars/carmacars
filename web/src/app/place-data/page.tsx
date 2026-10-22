import Link from 'next/link';
import { PageHead } from '@/components/Blocks';
import { JsonLd } from '@/components/JsonLd';
import { breadcrumbLd, seoMeta, type Trail } from '@/features/seo/meta';
import { getSettings } from '@/lib/site';

// Where the places on our place pages come from, and their licences (migration 0095). OpenStreetMap's ODbL asks that
// a database made from it be offered on request: this page says how.
export const revalidate = 86400;
const trail: Trail = [['Home', '/'], ['Place data']];
export async function generateMetadata() {
  return seoMeta({ title: 'Place Data Sources and Licences | CarmaCars', path: '/place-data',
    description: 'Where the cities, neighbourhoods and airports on CarmaCars place pages come from: GeoNames, OpenStreetMap and the US Census Bureau, and their licences.' });
}
export default async function PlaceData() {
  const s = await getSettings();
  return (
    <div className="p-legal">
      <JsonLd graph={[breadcrumbLd(trail, '/place-data')]} />
      <PageHead trail={trail} h1="Place data" lead="The cities, towns, neighbourhoods, airports and landmarks named on our place pages, their map positions and the links between them come from these sources." />
      <section className="section"><div className="wrap stack-lg measure">
        <div className="stack"><h2 className="d3">GeoNames</h2><p>Countries, provinces and states, regions, cities, airports and landmarks from the <a className="link" href="https://www.geonames.org/" rel="noopener">GeoNames</a> geographical database, licensed under <a className="link" href="https://creativecommons.org/licenses/by/4.0/" rel="noopener">Creative Commons Attribution 4.0</a>.</p></div>
        <div className="stack"><h2 className="d3">OpenStreetMap</h2><p>Neighbourhoods, towns and villages from <a className="link" href="https://www.openstreetmap.org/copyright" rel="noopener">© OpenStreetMap contributors</a>, available under the Open Database Licence (ODbL). Our places database is a derived database: you can ask for a copy of it under the same licence by writing to {s.public_email ? <a className="link" href={`mailto:${s.public_email}`}>{s.public_email}</a> : 'us'}.</p></div>
        <div className="stack"><h2 className="d3">US Census Bureau</h2><p>US cities and towns are checked against the Census Bureau&apos;s Gazetteer files, which are in the public domain.</p></div>
        <div className="stack"><h2 className="d3">What we add</h2><p>Distances are straight-line distances from our location in Toronto. Delivery prices come from our own rates. A place page never means we have a location there: CarmaCars has one location, in Toronto.</p></div>
        <p><Link className="link" href="/car-rental">Car rental by place</Link></p>
      </div></section>
    </div>
  );
}
