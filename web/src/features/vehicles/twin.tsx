import 'server-only';
import Link from 'next/link';
import type { Metadata } from 'next';
import { notFound, permanentRedirect } from 'next/navigation';
import { cache } from 'react';
import { JsonLd } from '@/components/JsonLd';
import { breadcrumbLd, faqLd, type Trail } from '@/features/seo/meta';
import { rpc } from '@/lib/db/repo';
import { money } from '@/lib/format';
import { fill, getClasses, getTokens, siteUrl } from '@/lib/site';
import { consentTexts } from '@/server/booking-data';
import { LeadForm } from './LeadForm';
import { buyDescriptionOptions, buyTitleOptions, dimRows, dimsFor, dollars, fit, fuelWord, list, priceBasis, ptName, ratingRange, ratingText, rentalFaq, specs, type Spec,
  termDescriptionOptions, termTitleOptions, type TermMode } from './content';
import { makePage, type MakePage, type ModelPage, tierPage, tiers as getTiers, trimPage, type TrimPage, yearPage, type YearPage, vehicleMeta } from './data';
import { CityBlock, cityFaq, colourFirst, StatsBlock, type Term, type TierPage, type Tiers, vehicleProps } from './deep';
import { CostBlock, InventoryBlock, productLd, Questions, requestHref, SpecsTable, standIn, VehicleHead, YearsTable } from './parts';
import '@/styles/vehicles.css';

// The twins of the vehicle pages (migration 0092): every page of the /cars tree again under /buy (for sale) and under
// /t/<term> for each search term: renting synonyms ("car hire"), sale ones ("used", "financing", "leasing"), detailing
// ("ceramic coating") and body shop work ("bumper repair"). The same sourced figures; then what the term is about:
// for sale, what to check (NHTSA recalls and complaints), "rent it for a week before you buy" and "Find me this car";
// for a renting term, our cars; for detailing and body shop, a request and, first, a rental while the car is in.
// CarmaCars mostly rents: a page says a car is for sale, with an Offer, only when an Admin flagged a matching fleet car,
// and a financing or leasing page says plainly that CarmaCars does not lend or lease.

type Recall = { campaign: string; date: string | null; component: string | null; summary: string | null };
type Complaints = { total: number; components: Array<{ component: string; n: number }> };
type ForSale = { name: string; year: number; colour: string | null; odometer_km: number | null; asking_price_cents: number; trim_slug: string | null; model_slug: string | null;
  listing: { slug: string; title?: string } | null };
export type BuyExtras = { for_sale: ForSale[]; buy_index: boolean; recalls: Recall[] | null; complaints: Complaints | null; by_year: Array<{ year: number; recalls: number; complaints: number }> | null };
type AnyPage = MakePage | ModelPage | YearPage | TrimPage | TierPage;
/** A tree: /buy (sale, no term) or /t/<term>. */
export type Tree = { base: string; mode: TermMode; term: Term | null };
export type Twin = { p: AnyPage; x: BuyExtras; tree: Tree };

const extras = cache(async (make: string, model: string | null, year: number | null, trim: string | null) =>
  ((await rpc('vehicle_buy_extras', { p_make: make, p_model: model as string, p_year: year as number, p_trim: trim as string })) as unknown as BuyExtras));
const SLUG = /^[a-z0-9]+(-[a-z0-9]+)*$/;
const labelsOf = async () => Object.fromEntries((await getClasses()).map((c) => [c.code, c.label]));

/** The tree of /t/<term> (404 for a term that is not active). */
export async function termTree(slug: string): Promise<Tree> {
  const t = (await getTiers()).terms.find((x) => x.slug === slug);
  if (!t) notFound();
  return { base: `/t/${t.slug}`, mode: t.kind, term: t };
}
export const BUY: Tree = { base: '/buy', mode: 'sale', term: null };

/** A twin's read: its /cars page's, and for sale what buying adds (cached per request by the tree and the address,
 *  so the metadata and the page share one read). */
export const twinPage = (tree: Tree, seg: string[]) => twinRead(tree.term?.slug ?? '', seg.join('/'));
const twinRead = cache(async (termSlug: string, path: string): Promise<Twin> => {
  const tree = termSlug ? await termTree(termSlug) : BUY;
  const seg = path.split('/');
  const [make, model, year, trim, city, colour] = seg;
  if (!make || !seg.every((s) => SLUG.test(s) && s.length <= 60) || seg.length > 6) notFound();
  let p: AnyPage;
  if (!model) { const m = await makePage(make); if (!m) notFound(); p = m; }
  else if (!year) {
    const m = (await rpc('vehicle_model_page', { p_make: make, p_model: model })) as unknown as (ModelPage & { redirect?: string }) | null;
    if (!m) notFound();
    if (m.redirect) permanentRedirect(`${tree.base}${m.redirect.slice(5)}`);
    p = m;
  } else if (!trim) p = await yearPage(make, model, year);
  else if (!city) p = await trimPage(make, model, year, trim);
  else if (city === 'colour') { if (!colour) notFound(); p = await tierPage(make, model, year, trim, null, colour); }
  else p = await tierPage(make, model, year, trim, city, colour ?? null);
  const x = tree.mode === 'sale' || tree.mode === 'bodyshop' ? await extras(make, model ?? null, year ? Number(year) : null, trim ?? null)
    : { for_sale: [], buy_index: true, recalls: null, complaints: null, by_year: null };
  return { p, x, tree };
});

const isTier = (p: AnyPage): p is TierPage => p.level === 'city' || p.level === 'colour' || p.level === 'city_colour';
const parts = (p: AnyPage) => {
  const model = 'model' in p ? p.model : null, year = 'year' in p ? p.year : null, trim = 'trim' in p ? p.trim : null;
  const t = isTier(p) ? p : null;
  return { make: p.make.name, model: model?.name, year: year ?? undefined, trim: trim?.name, city: t?.city?.name, colour: t?.colour?.name };
};
const nameOf = (p: AnyPage) => { const o = parts(p); return [o.year, o.make, o.model, o.trim].filter(Boolean).join(' '); };
const spOf = (p: AnyPage): Spec[] => ('variants' in p ? specs(p.variants, p.settings, 'trim' in p ? p.trim.variant_ids : undefined) : []);
const at = (tree: Tree, path: string) => `${tree.base}${path.slice(5)}`;
const FINANCE = /financ|leas|loan/;
/** Indexed: the page itself (its level, place and colour switches) and its tree's switches. */
function indexable(tw: Twin): boolean {
  const s = tw.p.settings as unknown as Record<string, unknown>;
  const on = (k: string) => s[k] !== false;
  const tree = tw.tree.term === null ? on('buy_index') : tw.tree.mode === 'sale' ? on('term_index') && on('buy_index') : tw.tree.mode === 'rental' ? on('term_index')
    : tw.tree.mode === 'detailing' ? on('detailing_index') : on('bodyshop_index');
  return tree && tw.p.indexable;
}
const bodyOf = (p: AnyPage) => ('vclass' in p && p.vclass ? p.vclass : 'model' in p && p.model.vclass ? p.model.vclass : null);
const lengthOf = (p: AnyPage) => { const d = 'dims' in p ? dimsFor(p.dims, parts(p).model ?? '', parts(p).trim)[0] : undefined; return d?.length_cm ? `${(d.length_cm / 100).toFixed(2)} m` : null; };

function titles(tw: Twin) {
  const o = parts(tw.p);
  const sp = spOf(tw.p);
  if (!tw.tree.term) return { title: buyTitleOptions(o), description: buyDescriptionOptions({ ...o, use: ratingRange(sp) || undefined, recalls: tw.x.recalls ? tw.x.recalls.length : null, forSale: tw.x.for_sale.length }) };
  const a = { ...o, mode: tw.tree.mode, term: tw.tree.term };
  return { title: termTitleOptions(a), description: termDescriptionOptions({ ...a, use: ratingRange(sp) || undefined, body: bodyOf(tw.p), length: lengthOf(tw.p), forSale: tw.x.for_sale.length,
    cars: tw.p.inventory.exact.length, recalls: tw.x.recalls ? tw.x.recalls.length : null }) };
}

export async function twinMeta(tw: Twin): Promise<Metadata> {
  const t = await getTokens();
  const { p } = tw;
  const o = parts(p);
  const ok = indexable(tw);
  const fallback = tw.tree.mode === 'sale' && tw.tree.term && (p.settings as unknown as Record<string, unknown>).buy_index !== false ? at(BUY, p.path) : p.path;
  const tt = titles(tw);
  return vehicleMeta({ title: fit(tt.title, (s) => fill(s, t), 70), path: at(tw.tree, p.path), indexable: ok, canonical: ok ? at(tw.tree, p.path) : fallback,
    description: fit(tt.description, (s) => fill(s, t), 170, 70),
    image: standIn({ path: isTier(p) ? p.trim_path : p.path, group: 'body_group' in p ? p.body_group : 'car', vclass: 'vclass' in p ? p.vclass : null, model: o.model ?? o.make, paint: isTier(p) ? p.colour?.slug : undefined }),
    imageAlt: `${o.colour ? `${o.colour} ` : ''}${nameOf(p)} studio image` });
}

function trailOf(tw: Twin, label: string): Trail {
  const { p, tree } = tw;
  const o = parts(p);
  const mk = `${tree.base}/${p.make.slug}`;
  const tr: Array<[string, string?]> = [['Home', '/'], [label, tree.base], [o.make, mk]];
  if ('model' in p) tr.push([p.model.name, `${mk}/${p.model.slug}`]);
  if ('year' in p) tr.push([String(p.year), `${mk}/${p.model.slug}/${p.year}`]);
  if ('trim' in p) tr.push([p.trim.name, at(tree, isTier(p) ? p.trim_path : p.path)]);
  if (isTier(p) && p.city) tr.push([p.city.name, `${at(tree, p.trim_path)}/${p.city.slug}`]);
  if (isTier(p) && p.colour) tr.push([p.colour.name, at(tree, p.path)]);
  const last = tr[tr.length - 1]!; tr[tr.length - 1] = [last[0]];
  return tr as Trail;
}

function ForSaleBlock({ items, name }: { items: ForSale[]; name: string }) {
  return (
    <section className="vp-sec" aria-labelledby="h-sale" data-testid="buy-for-sale">
      <h2 className="d3" id="h-sale">{items.length ? `For sale by us now` : `For sale`}</h2>
      {items.length ? <ul className="hub-grid">{items.map((c, i) => (
        <li key={i}><div className="hub-card"><h3>{c.name}</h3>
          <p><b>{money(c.asking_price_cents)}</b>{c.odometer_km ? `, ${c.odometer_km.toLocaleString('en-CA')} km` : ''}{c.colour ? `, ${c.colour.toLowerCase()}` : ''}</p>
          {c.listing?.slug && <p><Link prefetch={false} className="link" href={`/cars/${c.listing.slug}`}>See the car and rent it first</Link></p>}</div></li>))}</ul>
        : <p className="measure" data-testid="buy-none">We do not have a {name} for sale right now. We are a rental company: rent one for a week to try it, or tell us what you want and we look for one for you.</p>}
    </section>
  );
}

function Safety({ x, name }: { x: BuyExtras; name: string }) {
  if (x.by_year?.length) {
    return (
      <section className="vp-sec" aria-labelledby="h-safety" data-testid="buy-safety">
        <h2 className="d3" id="h-safety">Recalls and complaints by year</h2>
        <div className="table-scroll" tabIndex={0} role="region" aria-label={`${name} recalls and complaints by year`}>
          <table className="data"><caption className="vh">{name} NHTSA recalls and complaints by model year</caption>
            <thead><tr><th scope="col">Year</th><th scope="col" className="r">Recall campaigns</th><th scope="col" className="r">Complaints</th></tr></thead>
            <tbody>{x.by_year.map((y) => <tr key={y.year}><th scope="row">{y.year}</th><td className="r">{y.recalls}</td><td className="r">{y.complaints.toLocaleString('en-CA')}</td></tr>)}</tbody></table></div>
        <p className="xs muted">Source: NHTSA (US) recalls and owner complaints by model year. A recall in the US often has a Canadian twin from Transport Canada.</p>
      </section>
    );
  }
  if (!x.recalls && !x.complaints) return null;
  const r = x.recalls ?? []; const c = x.complaints;
  return (
    <section className="vp-sec" aria-labelledby="h-safety" data-testid="buy-safety">
      <h2 className="d3" id="h-safety">What to check when buying the {name}</h2>
      <ul className="featlist">
        <li>{r.length ? `NHTSA lists ${r.length} recall campaign${r.length === 1 ? '' : 's'} for this model year. Ask the seller for proof each one was fixed; a dealer can check it by the VIN.` : 'NHTSA lists no recall campaign for this model year.'}</li>
        {c && c.total > 0 && <li>Owners filed {c.total.toLocaleString('en-CA')} complaint{c.total === 1 ? '' : 's'} with NHTSA{c.components.length ? `, most often about ${list(c.components.slice(0, 3).map((k) => `${k.component.toLowerCase()} (${k.n})`))}` : ''}. Have those parts checked before you buy.</li>}
        {c && c.total === 0 && <li>No owner complaints are on file with NHTSA for this model year.</li>}
      </ul>
      {r.length > 0 && <div className="table-scroll" tabIndex={0} role="region" aria-label={`${name} recalls`}>
        <table className="data" data-testid="buy-recalls"><caption className="vh">{name} recall campaigns</caption>
          <thead><tr><th scope="col">Campaign</th><th scope="col">Date</th><th scope="col">Component</th><th scope="col">Summary</th></tr></thead>
          <tbody>{r.slice(0, 20).map((k) => <tr key={k.campaign}><th scope="row">{k.campaign}</th><td>{k.date ?? ''}</td><td>{k.component?.toLowerCase() ?? ''}</td><td className="wrap">{k.summary ?? ''}</td></tr>)}</tbody></table></div>}
      <p className="xs muted">Source: NHTSA (US) recall campaigns and owner complaints for this model year.</p>
    </section>
  );
}

function RentFirst({ rentPath, name, title, text, request, testId, linkText }: { rentPath: string; name: string; title: string; text: string; request: string; testId: string; linkText?: string }) {
  return (
    <section className="vp-sec vp-request vp-request--first" aria-labelledby={`h-${testId}`} data-testid={testId}>
      <div><h2 className="d3" id={`h-${testId}`}>{title}</h2><p className="small muted">{text}</p></div>
      <p className="ad-actions"><Link prefetch={false} className="btn" href={rentPath}>{linkText ?? `Rent the ${name}`}</Link>
        <Link prefetch={false} className="btn btn--primary" href={requestHref(request)} rel="nofollow">Request a rental</Link></p>
    </section>
  );
}

function buyFaq(name: string, x: BuyExtras, sp: Spec[]): Array<{ question: string; answer: string }> {
  const q = [{ question: `Does {{brand}} sell the ${name}?`, answer: x.for_sale.length ? `Yes: ${x.for_sale.length === 1 ? 'one is' : `${x.for_sale.length} are`} for sale by us now, listed at the top of this page with the asking price.` : `Not right now. {{brand}} rents cars; it sells one only now and then. Tell us what you want and we look for one, or rent one for a week first.` },
    { question: `Can I rent a ${name} before I buy one?`, answer: 'Yes. Request it for a week (or longer, up to {{maxDays}} days) and drive it as your own; nothing is charged until we confirm and you approve.' }];
  if (x.recalls) q.push({ question: `Does the ${name} have recalls?`, answer: x.recalls.length ? `NHTSA lists ${x.recalls.length} recall campaign${x.recalls.length === 1 ? '' : 's'} for it, in the table on this page. Ask for proof each was fixed.` : 'NHTSA lists no recall campaign for this model year.' });
  const fc = sp.find((s) => s.fuel_cost_usd);
  if (fc) q.push({ question: `What does the ${name} cost in fuel a year?`, answer: `EPA puts it at US$${fc.fuel_cost_usd!.toLocaleString('en-US')} a year for 15,000 miles at its fuel prices${fc.cost100 !== null ? `; at our price setting, 20,000 km cost about ${dollars(fc.cost100 * 200)}` : ''}.` });
  q.push({ question: 'Where do the figures come from?', answer: 'Fuel use and fuel cost from the US EPA (fueleconomy.gov), dimensions and weight from NHTSA vPIC Canadian specifications, recalls and complaints from NHTSA. We leave out any figure no free source publishes.' });
  return q;
}

function serviceFaq(tw: Twin, name: string, dims: ReturnType<typeof dimsFor>): Array<{ question: string; answer: string }> {
  const svc = tw.tree.term!.name.toLowerCase();
  const body = tw.tree.mode === 'bodyshop';
  const q = [{ question: `Can I rent a car while my ${name} is in for ${svc}?`, answer: body
      ? 'Yes. Rent from us while it is repaired: an insurance replacement rental if the repair is an insurance claim (ask your insurer what your policy pays a day), or at our usual rates. We deliver the car to you.'
      : 'Yes. Rent from us while it is detailed, by the day, at our usual rates; we deliver the car to you and pick it up when yours is ready.' },
    { question: `How do I book ${svc} for my ${name}?`, answer: 'Send the request on this page with when suits you. We reply within one business day with a time and a price.' }];
  if (dims[0]?.length_cm) q.push({ question: `How big is the ${name}?`, answer: `${dims.map((d) => `${d.body.toLowerCase()}: ${(Number(d.length_cm) / 100).toFixed(2)} m long${d.width_cm ? `, ${(d.width_cm / 100).toFixed(2)} m wide` : ''}${d.height_cm ? `, ${(d.height_cm / 100).toFixed(2)} m high` : ''}`).join('; ')} (NHTSA vPIC Canadian specifications).` });
  return q;
}

/** The term tree's start: /t/<term> lists every make. */
export async function TermIndex({ tree }: { tree: Tree }) {
  const makes = ((await rpc('vehicle_makes', {})) as unknown as Array<{ slug: string; name: string }> | null) ?? [];
  const label = tree.term!.name;
  const trail: Trail = [['Home', '/'], [label]];
  return (
    <div className="p-vehicle" data-page="term-index">
      <JsonLd graph={[breadcrumbLd(trail, tree.base)]} />
      <VehicleHead trail={trail} h1={`${label}: every make, model, year and trim`} lead={`${label} for every car: its own figures from the EPA and NHTSA, by place and colour.`} img="/sample-photos/studio/sedan/grey/lead/CARMACARS.svg" alt="A car in the studio, a representative image" facts={[]} cta={['#h-makes', 'Choose a make']} />
      <div className="wrap vp-body"><section className="vp-sec" aria-labelledby="h-makes"><h2 className="d3" id="h-makes">Makes</h2>
        <ul className="chips">{makes.map((m) => <li key={m.slug}><Link prefetch={false} className="chip" href={`${tree.base}/${m.slug}`}>{m.name}</Link></li>)}</ul></section></div>
    </div>
  );
}

export async function TwinView(tw: Twin) {
  const { p, x, tree } = tw;
  const [t, consent, tiers, labels] = await Promise.all([getTokens(), consentTexts(), getTiers(), labelsOf()]);
  const F = (s: string) => fill(s, t);
  const o = parts(p);
  const name = nameOf(p);
  const full = [o.colour?.toLowerCase(), name].filter(Boolean).join(' ');
  const path = at(tree, p.path);
  const sp = spOf(p);
  const trimPath = isTier(p) ? p.trim_path : p.path;
  const img = standIn({ path: trimPath, group: 'body_group' in p ? p.body_group : 'car', vclass: 'vclass' in p ? p.vclass : null, model: o.model ?? o.make, paint: isTier(p) ? p.colour?.slug : undefined });
  const mode = tree.mode;
  const svc = mode === 'detailing' || mode === 'bodyshop';
  const label = tree.term?.name ?? 'Buy';
  const trail = trailOf(tw, label);
  const cap1 = (s: string) => s.charAt(0).toUpperCase() + s.slice(1);
  // the H1: the page's own name, the title without the brand and without its ": specs and..." ending
  const h1 = tree.term ? fill(titles(tw).title[0]!.replace(/ \| \{\{brand\}\}$/, '').replace(/: specs.*$/, ''), t) : `${cap1(full)} for sale${o.city ? ` in ${o.city}` : ''}`;
  const dims = 'dims' in p ? dimsFor(p.dims, o.model ?? '', o.trim) : [];
  const where = o.city ? ` in ${o.city}` : '';
  const inv = colourFirst(p.inventory, isTier(p) ? p.colour?.slug ?? null : null);
  const finance = mode === 'sale' && !!tree.term && (tree.term.lead === 'finance' || FINANCE.test(tree.term.slug));
  const disclaimer = String((p.settings as unknown as Record<string, unknown>).finance_disclaimer ?? '');
  const lead = mode === 'sale'
    ? [x.for_sale.length ? `${x.for_sale.length === 1 ? 'One' : x.for_sale.length} for sale by us now, from ${money(Math.min(...x.for_sale.map((c) => c.asking_price_cents)))}.` : `None for sale by us right now: rent one for a week first, or ask us to find one.`,
       sp.length ? `Rated ${ratingRange(sp)} combined (EPA).` : '', x.recalls ? `${x.recalls.length} NHTSA recall campaign${x.recalls.length === 1 ? '' : 's'}.` : '', finance ? disclaimer : ''].filter(Boolean).join(' ')
    : svc ? `${tree.term!.name} for the ${full}${where}: request it here. ${mode === 'bodyshop' ? 'Rent a car from us while it is repaired, as an insurance replacement rental when it is a claim.' : 'Rent a car from us while yours is detailed.'}`
    : `${tree.term!.name} for the ${full}${where}. ${sp.length ? `Rated ${ratingRange(sp)} combined (EPA).` : ''} ${inv.exact.length ? `${inv.exact.length} of ours to rent now.` : 'Request one, or rent a similar car now.'}`.replace(/\s+/g, ' ').trim();
  const cheapest = sp.filter((s) => s.cost100 !== null)[0];
  const faqRaw = [...(isTier(p) && p.city ? cityFaq(p.city, name).slice(0, svc ? 1 : 2) : []),
    ...(mode === 'sale' ? buyFaq(full, x, sp) : svc ? serviceFaq(tw, name, dims) : rentalFaq({ name, cars: inv.exact.length, similar: inv.similar.length + inv.same_model.length, ev: cheapest?.fuel === 'electric',
      cost100: cheapest ? dollars(cheapest.cost100) : null, cheapestUse: cheapest ? `${ratingText(cheapest)} (${ptName(cheapest)})` : undefined, basis: cheapest ? priceBasis(cheapest, p.settings) : undefined }))];
  const faq = faqRaw.map((q) => ({ question: F(q.question), answer: F(q.answer) }));
  const offers = x.for_sale.map((c) => ({ '@type': 'Offer', price: (c.asking_price_cents / 100).toFixed(2), priceCurrency: 'CAD', availability: 'https://schema.org/InStock', itemCondition: 'https://schema.org/UsedCondition',
    businessFunction: 'http://purl.org/goodrelations/v1#Sell', seller: { '@id': `${siteUrl()}/#business` }, url: siteUrl() + path, name: c.name }));
  const ld = 'model' in p ? productLd({ name: full, make: o.make, model: o.model!, year: o.year, trim: o.trim, path, image: img, description: lead, inv: p.inventory, offers: mode === 'rental',
    fuel: sp[0] ? fuelWord(sp[0].fuel) : undefined, body: 'vclass' in p ? p.vclass : null, extra: { ...vehicleProps(sp, dims, null, o.colour ?? null), ...(mode === 'sale' && offers.length ? { offers } : {}) } }) : null;
  const rentPath = p.path;
  const rentReplacement = tiers.terms.some((x2) => x2.slug === 'insurance-replacement') ? `/t/insurance-replacement${p.path.slice(5)}` : p.path;
  const kindForm = mode === 'sale' ? (finance ? 'finance' : 'buyer') : mode === 'detailing' ? 'detailing' : 'bodyshop';
  const drows = dimRows(dims);
  return (
    <div className="p-vehicle" data-page={`${tree.term ? `term-${mode}` : 'buy'}-${p.level.replace('_', '-')}`}>
      <JsonLd graph={[breadcrumbLd(trail, path), ...(ld ? [ld] : []), faqLd(faq)]} />
      <VehicleHead trail={trail} h1={h1} lead={lead} img={img} alt={`${full} in the studio, a representative image`}
        cta={mode === 'sale' ? (x.for_sale.length ? ['#h-sale', 'See the cars for sale'] : ['#find', finance ? 'Ask about it' : 'Find me this car']) : svc ? ['#find', 'Request it'] : ['#inventory', 'See cars to rent']}
        facts={[...(mode === 'sale' ? [['For sale by us', String(x.for_sale.length)] as [string, string]] : []), ['Combined', sp.length ? ratingRange(sp).split(', or')[0]! : ''],
          ...(svc && bodyOf(p) ? [['Body', String(bodyOf(p))] as [string, string]] : []), ...(svc && lengthOf(p) ? [['Length', String(lengthOf(p))] as [string, string]] : []),
          ...(mode === 'sale' ? [['Recalls', x.recalls ? String(x.recalls.length) : ''] as [string, string]] : [])].filter(([, v]) => v) as Array<[string, string]>} />
      <div className="wrap vp-body">
        {svc && <RentFirst rentPath={mode === 'bodyshop' ? rentReplacement : rentPath} name={name} testId="svc-rent-first" linkText="See cars to rent"
          title={mode === 'bodyshop' ? 'An insurance replacement rental while it is repaired' : 'Rent a car while yours is detailed'}
          text={mode === 'bodyshop' ? 'Your car is in the shop; you keep driving. We deliver a rental to you, by the day, and bill your insurer when the claim covers it.' : 'Keep driving while your car is in: we deliver a rental to you and collect it when yours is ready.'}
          request={mode === 'bodyshop' ? `insurance replacement rental while my ${name} is repaired` : `a rental while my ${name} is detailed`} />}
        {mode === 'sale' && <ForSaleBlock items={x.for_sale} name={full} />}
        {finance && <p className="alert" data-testid="finance-disclaimer"><span>{disclaimer}</span></p>}
        {isTier(p) && p.city && <CityBlock c={p.city} name={name} linkBase={at(tree, p.trim_path)} colour={p.colour?.slug} />}
        {p.level === 'make' && <section className="vp-sec" aria-labelledby="h-models"><h2 className="d3" id="h-models">{o.make} models</h2>
          <ul className="hub-grid" data-testid="vp-models">{(p as MakePage).models.map((m) => <li key={m.slug}><Link prefetch={false} className="hub-card" href={at(tree, m.path)}><h3>{o.make} {m.name}</h3>
            <p>{m.first_year === m.last_year ? m.first_year : `${m.first_year} to ${m.last_year}`}</p></Link></li>)}</ul></section>}
        {p.level === 'model' && <section className="vp-sec" aria-labelledby="h-years"><h2 className="d3" id="h-years">Every {name} year</h2>
          <YearsTable years={(p as ModelPage).years.map((y) => ({ ...y, path: at(tree, y.path) }))} caption={`${name} model years`} /></section>}
        {svc && (drows.length > 0 || bodyOf(p)) && <section className="vp-sec" aria-labelledby="h-svcfacts" data-testid="svc-facts">
          <h2 className="d3" id="h-svcfacts">The {full} for {tree.term!.name.toLowerCase()}</h2>
          <ul className="featlist">{bodyOf(p) && <li>Body: {String(bodyOf(p)).toLowerCase()} (EPA size class).</li>}{o.colour && <li>Colour: {o.colour.toLowerCase()}.</li>}
            {dims.length > 1 && <li>{dims.length} bodies this year: {list(dims.map((d) => d.body.toLowerCase()))}.</li>}</ul>
        </section>}
        {sp.length > 0 && !svc && <section className="vp-sec" aria-labelledby="h-specs"><h2 className="d3" id="h-specs">{full} specs</h2><SpecsTable sp={sp} caption={`${name} powertrains`} /></section>}
        {'variants' in p && <StatsBlock sp={sp} dims={'dims' in p ? p.dims : undefined} model={o.model ?? ''} trim={o.trim} name={full} s={p.settings} />}
        {mode === 'rental' && <CostBlock sp={sp} s={p.settings} name={name} />}
        {(mode === 'sale' || mode === 'bodyshop') && <Safety x={x} name={name} />}
        {p.level === 'year' && (p as YearPage).trims.length > 0 && <section className="vp-sec" aria-labelledby="h-trims"><h2 className="d3" id="h-trims">The {name} trims in Canada</h2>
          <ul className="chips">{(p as YearPage).trims.map((tr) => <li key={tr.slug}><Link prefetch={false} className="chip" href={at(tree, tr.path)}>{tr.name}</Link></li>)}</ul></section>}
        {(p.level === 'trim' || isTier(p)) && <TwinLinks tree={tree} base={at(tree, trimPath)} tiers={tiers} city={isTier(p) ? p.city?.slug : null} colour={isTier(p) ? p.colour?.slug : null} siblings={(p as TrimPage).siblings} trim={(p as TrimPage).trim.slug} trimPath={trimPath} />}
        {mode === 'sale' && <RentFirst rentPath={rentPath} name={full} testId="buy-rent-first" title="Rent it for a week before you buy"
          text={`A week of your own driving tells you more than a test drive: the commute, the parking, the fuel. Rent a ${full} from us first.`} request={`${full} for a week, before buying`} />}
        {mode !== 'rental' && <section className="vp-sec" aria-labelledby="h-find" id="find">
          <h2 className="d3" id="h-find">{mode === 'sale' ? (finance ? `Ask us about the ${full}` : 'Find me this car') : `Request ${tree.term!.name.toLowerCase()}`}</h2>
          <p className="small muted measure">{mode === 'sale' ? `Tell us your budget and when you want to buy; we look for a ${full} for you and reply within one business day.` : `Tell us when suits you; we reply within one business day with a time and a price.`}</p>
          <LeadForm kind={kindForm} vehicle={full} service={tree.term?.name} place={o.city} marketingText={consent.marketing.text} disclaimer={finance ? disclaimer : undefined} />
        </section>}
      </div>
      {(mode === 'rental' || svc) && <InventoryBlock inv={svc ? { ...inv, exact: [], same_model: [] } : inv} labels={labels} name={svc ? 'car while yours is in' : full}
        exactLabel={`Our ${name} cars`} sameLabel={`Other ${o.make} ${o.model ?? ''} cars we have`} />}
      <div className="wrap vp-body"><Questions items={faq} title={mode === 'sale' ? `Buying the ${full}` : `${tree.term?.name ?? 'Renting'}: the ${full}`} /></div>
    </div>
  );
}

function TwinLinks({ tree, base, tiers, city, colour, siblings, trim, trimPath }: { tree: Tree; base: string; tiers: Tiers; city?: string | null; colour?: string | null; siblings: TrimPage['siblings']; trim: string; trimPath: string }) {
  const tail = `${city ? `/${city}` : ''}${colour ? (city ? `/${colour}` : `/colour/${colour}`) : ''}`;
  const rest = `${trimPath.slice(5)}${tail}`;
  return (
    <section className="vp-sec" aria-labelledby="h-btiers" data-testid="buy-tiers">
      <h2 className="d3" id="h-btiers">Other trims, places, colours and searches</h2>
      <ul className="chips">{siblings.filter((s) => s.slug !== trim).map((s) => <li key={s.slug}><Link prefetch={false} className="chip" href={`${at(tree, s.path)}${tail}`}>{s.name}</Link></li>)}</ul>
      <ul className="chips">{tiers.places.filter((c) => c.slug !== city).map((c) => <li key={c.slug}><Link prefetch={false} className="chip" href={`${base}/${c.slug}${colour ? `/${colour}` : ''}`}>{c.name}</Link></li>)}</ul>
      <ul className="chips">{tiers.colours.filter((c) => c.slug !== colour).map((c) => <li key={c.slug}><Link prefetch={false} className="chip" href={city ? `${base}/${city}/${c.slug}` : `${base}/colour/${c.slug}`}>{c.name}</Link></li>)}</ul>
      <ul className="chips"><li><Link prefetch={false} className="chip" href={`/cars${rest}`}>Rent</Link></li><li><Link prefetch={false} className="chip" href={`/buy${rest}`}>For sale</Link></li>
        {tiers.terms.filter((x) => x.slug !== tree.term?.slug).map((x) => <li key={x.slug}><Link prefetch={false} className="chip" href={`/t/${x.slug}${rest}`}>{x.name}</Link></li>)}</ul>
    </section>
  );
}
