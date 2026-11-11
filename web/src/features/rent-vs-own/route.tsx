import { notFound } from 'next/navigation';
import { cache } from 'react';
import { SeoShell } from '@/features/seo/Shell';
import { seoMeta } from '@/features/seo/meta';
import { getMaintenance } from '@/features/seo/depth-data';
import { rpc } from '@/lib/db/repo';
import { money } from '@/lib/format';
import { getClasses, getFleet, getSettings } from '@/lib/site';
import { ownLines, type OwnInputs } from './calc';

// The renting vs owning pages (release 36, part 11): /rent-vs-own/<make>/<model>/<year>[/<city>]. Every line from a
// source or a Program setting, with its basis and source shown; the CarmaCars monthly rental beside the total.
type Page = OwnInputs & { make: string; model: string; year: number; make_slug: string; model_slug: string; city: { slug: string; name: string } | null; years: number[]; cities: Array<{ slug: string; name: string }> };
const SLUG = /^[a-z0-9]+(-[a-z0-9]+)*$/;
const load = cache(async (make: string, model: string, year: string, city: string | null): Promise<Page | null> => {
  if (![make, model].every((x) => SLUG.test(x)) || !/^(19|20)\d\d$/.test(year) || (city !== null && !SLUG.test(city))) return null;
  try { return ((await rpc('rent_vs_own_page', { p_make: make, p_model: model, p_year: Number(year), p_city: city as string })) ?? null) as unknown as Page | null; } catch { return null; }
});
const pathOf = (p: Page) => `/rent-vs-own/${p.make_slug}/${p.model_slug}/${p.year}${p.city ? `/${p.city.slug}` : ''}`;

export async function rvoMeta(make: string, model: string, year: string, city: string | null) {
  const p = await load(make, model, year, city);
  if (!p) return {};
  // the model year's own page names no city (its Toronto page has the same figures and says Toronto): titles stay unique
  const where = p.city ? ` in ${p.city.name}` : '';
  return seoMeta({ title: `${p.year} ${p.make} ${p.model}: Renting vs Owning${where}`.slice(0, 70), path: pathOf(p),
    description: `What a ${p.year} ${p.make} ${p.model} costs to own each month${where}, line by line with sources, against renting by the month from CarmaCars.`.slice(0, 165) });
}
export async function RentVsOwn({ make, model, year, city }: { make: string; model: string; year: string; city: string | null }) {
  const p = await load(make, model, year, city);
  if (!p) notFound();
  const [s, fleet, classes, maint] = await Promise.all([getSettings(), getFleet().catch(() => []), getClasses(), getMaintenance(p.make, p.catalog?.vclass ?? null)]);
  const { lines, insurance, msrp } = ownLines({ ...p, maintenance: maint }, p.year);
  const total = lines.reduce((n, l) => n + l.monthly_cents, 0);
  const rent = p.rental?.monthly_cents ?? p.rental_any ?? null;
  const name = `${p.year} ${p.make} ${p.model}`;
  const where = p.city?.name ?? 'Toronto';
  const path = pathOf(p);
  const lead = [`What a ${name} costs to own each month in ${where}, line by line, and what renting one from ${s.brand_name} by the month costs instead. Every figure shows where it comes from; a figure no source gives is left out.`];
  if (rent && lines.length) lead.push(`Owning, before insurance: about ${money(total)} a month. Renting from ${s.brand_name}: from ${money(rent)} a month${p.rental ? ` for a ${p.make} ${p.model}` : ' for our lowest-priced car'}: maintenance and registration are ours, and third-party liability coverage is included.`);
  const faq = [
    ...(lines.length ? [{ question: `How much does a ${name} cost to own each month?`, answer: `About ${money(total)} before insurance: ${lines.map((l) => `${l.label.toLowerCase()} ${money(l.monthly_cents)}`).join(', ')}.` }] : []),
    ...(rent ? [{ question: `How much is it to rent instead?`, answer: `From ${money(rent)} a month with ${s.brand_name}, before HST.` }] : [])
  ];
  return (
    <SeoShell path={path} testId="rent-vs-own" trail={[['Home', '/'], ['Renting vs owning', '/rent-vs-own'], [name, p.city ? `/rent-vs-own/${p.make_slug}/${p.model_slug}/${p.year}` : undefined], ...(p.city ? [[p.city.name] as [string]] : [])]}
      h1={`${name}: renting vs owning${p.city ? ` in ${p.city.name}` : ''}`} lead={lead}
      facts={[...(msrp ? [['MSRP', money(msrp)] as [string, string]] : []), ...(lines.length ? [['Owning, a month', `${money(total)} + insurance`] as [string, string]] : []), ...(rent ? [['Renting, a month', `from ${money(rent)}`] as [string, string]] : [])]}
      cars={fleet} labels={Object.fromEntries(classes.map((x) => [x.code, x.label]))} want={`a ${p.make} ${p.model}`} carsTitle="Rent one by the month" faq={faq}
      links={[...p.years.filter((y) => y !== p.year).slice(0, 8).map((y) => ({ href: `/rent-vs-own/${p.make_slug}/${p.model_slug}/${y}`, label: `${y} ${p.make} ${p.model}: renting vs owning` })),
        ...p.cities.filter((c) => c.slug !== p.city?.slug).slice(0, 12).map((c) => ({ href: `/rent-vs-own/${p.make_slug}/${p.model_slug}/${p.year}/${c.slug}`, label: `${name} in ${c.name}` }))]}>
      {lines.length > 0 && (
        <section className="car-sec landing__sec" aria-labelledby="h-own" data-testid="own-costs">
          <h2 className="d2" id="h-own">The monthly cost of owning</h2>
          <div className="table-scroll" tabIndex={0} role="region" aria-label="The monthly cost of owning">
            <table className="data data--min"><thead><tr><th scope="col">Cost</th><th scope="col">A month</th><th scope="col">How</th><th scope="col">Source</th></tr></thead>
              <tbody>{lines.map((l) => <tr key={l.key}><th scope="row">{l.label}</th><td>{money(l.monthly_cents)}</td><td>{l.basis}</td><td>{l.source_url ? <a className="link" href={l.source_url} rel="nofollow noopener">{l.source}</a> : l.source}</td></tr>)}
                <tr><th scope="row">Total, before insurance</th><td><b>{money(total)}</b></td><td /><td /></tr>
                {rent && <tr><th scope="row">Renting from {s.brand_name}</th><td><b>from {money(rent)}</b></td><td>The monthly rate on this site, before HST</td><td>{s.brand_name}</td></tr>}</tbody></table>
          </div>
        </section>
      )}
      {insurance.length > 0 && (
        <section className="car-sec landing__sec" aria-labelledby="h-ins">
          <h2 className="d2" id="h-ins">Insurance, by age</h2>
          <ul className="linklist">{insurance.map((c) => <li key={c.scope}>{c.scope.split('|')[0]}: about {money(c.monthly_cents)} a month ({c.source}){c.note ? `. ${c.note}` : ''}</li>)}</ul>
        </section>
      )}
    </SeoShell>
  );
}
export async function RentVsOwnHub() {
  let rows: Array<{ path: string }> = [];
  try { rows = (((await rpc('sitemap_families', {})) ?? []) as unknown as Array<{ path: string }>); } catch { /* none */ }
  const models = rows.map((r) => /^\/rent-vs-own\/([^/]+)\/([^/]+)\/(\d{4})$/.exec(r.path)).filter(Boolean).map((m) => ({ href: m![0], label: `${m![3]} ${m![1]} ${m![2]}`.replace(/-/g, ' ') })).slice(0, 300);
  return <SeoShell path="/rent-vs-own" testId="rent-vs-own-hub" trail={[['Home', '/'], ['Renting vs owning']]} h1="Renting vs owning a car in Toronto"
    lead={['The monthly cost of owning a popular model, line by line with sources, against renting one by the month.']} links={models} linksTitle="Models" />;
}
