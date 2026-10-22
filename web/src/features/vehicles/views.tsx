import Link from 'next/link';
import type { Metadata } from 'next';
import { JsonLd } from '@/components/JsonLd';
import { breadcrumbLd, faqLd, type Trail } from '@/features/seo/meta';
import { fill, getClasses, getTokens, siteUrl } from '@/lib/site';
import { descriptionOptions, dimsFor, fit, fuelWord, list, ptName, rentalFaq, specs, titleOptions, trimDiffs, ratingRange, ratingText, yearChanges, priceBasis, dollars } from './content';
import { type MakePage, type ModelPage, type TrimPage, type YearPage, tiers as getTiers, vehicleMeta } from './data';
import { StatsBlock, TierLinks, vehicleProps } from './deep';
import { CostBlock, InventoryBlock, productLd, Questions, SimilarModels, SpecsTable, standIn, VehicleHead, YearsTable, fromPrice } from './parts';
import '@/styles/vehicles.css';

// The four vehicle pages (migration 0092; docs/changes/2026-10-21-vehicle-pages.md). Every sentence comes from the
// page's own data: the EPA powertrains, the Canadian trims, the other years and trims, our cars and the settings.

const labelsOf = async () => Object.fromEntries((await getClasses()).map((c) => [c.code, c.label]));
const lower = (s: string | null) => (s ?? '').toLowerCase();
const EPA_NOTE = 'Fuel use is the US EPA rating (fueleconomy.gov) converted to litres per 100 km; Canadian ratings can differ slightly. Trim names are the Canadian lineup.';

// ---------------------------------------------------------------- make
export async function makeMeta(p: MakePage): Promise<Metadata> {
  const t = await getTokens();
  const years = p.models.flatMap((m) => [m.first_year, m.last_year]);
  return vehicleMeta({ title: fit(titleOptions({ make: p.make.name }), (x) => fill(x, t), 70), path: p.path, indexable: p.indexable, canonical: p.canonical,
    description: fit(descriptionOptions({ make: p.make.name, count: p.models.length, firstYear: years.length ? Math.min(...years) : undefined, lastYear: years.length ? Math.max(...years) : undefined, cars: p.inventory.real_exact }), (x) => fill(x, t), 170, 70),
    image: standIn({ path: p.path, group: 'car', vclass: null, model: p.make.name }), imageAlt: `${p.make.name} studio image` });
}

export async function MakeView({ p }: { p: MakePage }) {
  const [t, labels] = await Promise.all([getTokens(), labelsOf()]);
  const name = p.make.name;
  const trail: Trail = [['Home', '/'], ['Fleet', '/cars'], [name]];
  const img = standIn({ path: p.path, group: 'car', vclass: null, model: name });
  const years = p.models.flatMap((m) => [m.first_year, m.last_year]);
  const evs = p.models.filter((m) => m.fuels.includes('electric')), hy = p.models.filter((m) => m.fuels.some((f) => f === 'hybrid' || f === 'plug_in_hybrid'));
  const best = [...p.models].filter((m) => m.l100_min !== null && !m.fuels.includes('electric')).sort((a, b) => Number(a.l100_min) - Number(b.l100_min))[0];
  const current = p.models.filter((m) => m.last_year >= new Date().getFullYear() - 1);
  const lead = p.models.length
    ? `${p.models.length} ${name} models from ${Math.min(...years)} to ${Math.max(...years)}, ${current.length} of them current. ${evs.length ? `${evs.length} electric, ` : ''}${hy.length ? `${hy.length} with a hybrid, ` : ''}${best ? `the most efficient gas model is the ${best.name} at ${Number(best.l100_min).toFixed(1)} L/100 km.` : ''}`.replace(/, $/, '.')
    : `Our ${name} cars to rent in ${t.city}.`;
  const faq = rentalFaq({ name, cars: p.inventory.exact.length, similar: p.inventory.similar.length, ev: false });
  const F = (x: string) => fill(x, t);
  return (
    <div className="p-vehicle" data-page="vehicle-make">
      <JsonLd graph={[breadcrumbLd(trail, p.path), faqLd(faq.map((q) => ({ question: F(q.question), answer: F(q.answer) }))),
        { '@type': 'ItemList', name: `${name} models`, itemListElement: p.models.slice(0, 100).map((m, i) => ({ '@type': 'ListItem', position: i + 1, url: siteUrl() + m.path, name: `${name} ${m.name}` })) }]} />
      <VehicleHead trail={trail} h1={`Rent a ${name} in ${t.city}`} lead={lead} img={img} alt={`${name} in the studio, a representative image`}
        facts={[['Models', String(p.models.length)], ['Years', years.length ? `${Math.min(...years)} to ${Math.max(...years)}` : ''], ['Our cars', String(p.inventory.exact.length)]].filter(([, v]) => v) as Array<[string, string]>} />
      <div className="wrap vp-body">
        <section className="vp-sec" aria-labelledby="h-models">
          <h2 className="d3" id="h-models">{name} models</h2>
          {p.models.length ? <ul className="hub-grid" data-testid="vp-models">{p.models.map((m) => (
            <li key={m.slug}><Link prefetch={false} className="hub-card" href={m.path}><h3>{name} {m.name}</h3>
              <p>{m.first_year === m.last_year ? m.first_year : `${m.first_year} to ${m.last_year}`}{m.vclass ? `, ${lower(m.vclass)}` : ''}</p>
              <p>{m.kwh100_min !== null ? `Electric, from ${Number(m.kwh100_min).toFixed(1)} kWh/100 km` : m.l100_min !== null ? `From ${Number(m.l100_min).toFixed(1)} L/100 km` : 'Not rated by EPA'}{m.trims ? `, ${m.trims} Canadian trims` : ''}</p></Link></li>))}</ul>
            : <p className="small muted">The catalog has no {name} models yet; our cars are below.</p>}
          <p className="xs muted">{EPA_NOTE}</p>
        </section>
      </div>
      <div className="wrap vp-body"><p className="small" data-testid="vp-buy-link"><Link prefetch={false} className="link" href={`/buy${p.path.slice(5)}`}>Buying a {name}? Specs, recalls and what to check</Link></p></div>
      <InventoryBlock inv={p.inventory} labels={labels} name={name} exactLabel={`Our ${name} cars`} sameLabel="" />
      <div className="wrap vp-body"><Questions items={faq.map((q) => ({ question: F(q.question), answer: F(q.answer) }))} title={`Renting a ${name} in ${t.city}`} /></div>
    </div>
  );
}

// ---------------------------------------------------------------- model
export async function modelMeta(p: ModelPage): Promise<Metadata> {
  const t = await getTokens();
  const ys = p.years.map((y) => y.year);
  const l = p.years.map((y) => y.l100_min).filter((x): x is number => x !== null).map(Number);
  return vehicleMeta({ title: fit(titleOptions({ make: p.make.name, model: p.model.name }), (x) => fill(x, t), 70), path: p.path, indexable: p.indexable, canonical: p.canonical,
    description: fit(descriptionOptions({ make: p.make.name, model: p.model.name, firstYear: ys.length ? Math.min(...ys) : undefined, lastYear: ys.length ? Math.max(...ys) : undefined,
      use: l.length ? `from ${Math.min(...l).toFixed(1)} L/100 km` : undefined, cars: p.inventory.exact.length }), (x) => fill(x, t), 170, 70),
    image: standIn({ path: p.path, group: p.body_group, vclass: p.model.vclass, model: p.model.name }), imageAlt: `${p.make.name} ${p.model.name} studio image` });
}

export async function ModelView({ p }: { p: ModelPage }) {
  const [t, labels] = await Promise.all([getTokens(), labelsOf()]);
  const name = `${p.make.name} ${p.model.name}`;
  const trail: Trail = [['Home', '/'], ['Fleet', '/cars'], [p.make.name, `/cars/${p.make.slug}`], [p.model.name]];
  const img = standIn({ path: p.path, group: p.body_group, vclass: p.model.vclass, model: p.model.name });
  const ys = p.years.map((y) => y.year);
  const rated = p.years.filter((y) => y.l100_min !== null || y.kwh100_min !== null);
  const bestYear = [...rated].sort((a, b) => Number(a.l100_min ?? a.kwh100_min) - Number(b.l100_min ?? b.kwh100_min))[0];
  const trimNames = [...new Set(p.years.flatMap((y) => y.trims.map((x) => x.name)))];
  const lead = ys.length
    ? `The ${name}${p.model.vclass ? `, a ${lower(p.model.vclass).replace(/s$/, '')},` : ''} in ${ys.length} model years from ${Math.min(...ys)} to ${Math.max(...ys)}.${bestYear ? ` The most efficient is the ${bestYear.year} at ${bestYear.kwh100_min !== null ? `${Number(bestYear.kwh100_min).toFixed(1)} kWh/100 km` : `${Number(bestYear.l100_min).toFixed(1)} L/100 km`} combined.` : ''}${trimNames.length ? ` Canadian trims include ${list(trimNames.slice(0, 5))}.` : ''}`
    : `Our ${name} cars to rent in ${t.city}.`;
  const price = fromPrice(p.inventory);
  const latest = rated[0];
  const cost = latest ? (latest.kwh100_min !== null ? Math.round(Number(latest.kwh100_min) * p.settings.elec_cents) : Math.round(Number(latest.l100_min) * p.settings.gas_cents)) : null;
  const faq = rentalFaq({ name, cars: p.inventory.exact.length, similar: p.inventory.similar.length, ev: !!latest && latest.kwh100_min !== null,
    cost100: cost !== null ? dollars(cost) : null, cheapestUse: latest ? (latest.kwh100_min !== null ? `${Number(latest.kwh100_min).toFixed(1)} kWh/100 km for the ${latest.year}` : `${Number(latest.l100_min).toFixed(1)} L/100 km for the ${latest.year}`) : undefined,
    basis: latest ? priceBasis({ fuel: latest.kwh100_min !== null ? 'electric' : 'gasoline' }, p.settings) : undefined });
  const F = (x: string) => fill(x, t);
  return (
    <div className="p-vehicle" data-page="vehicle-model">
      <JsonLd graph={[breadcrumbLd(trail, p.path), productLd({ name, make: p.make.name, model: p.model.name, path: p.path, image: img, description: lead, inv: p.inventory }),
        faqLd(faq.map((q) => ({ question: F(q.question), answer: F(q.answer) })))]} />
      <VehicleHead trail={trail} h1={`Rent a ${name} in ${t.city}`} lead={lead} img={img} alt={`${name} in the studio, a representative image`}
        facts={[['Years', ys.length ? `${Math.min(...ys)} to ${Math.max(...ys)}` : ''], ['Our cars', String(p.inventory.exact.length)], ...(price ? [['From', `${price} a day`]] : [])].filter(([, v]) => v) as Array<[string, string]>} />
      <div className="wrap vp-body">
        {p.years.length > 0 && <section className="vp-sec" aria-labelledby="h-years">
          <h2 className="d3" id="h-years">Every {name} year</h2>
          <YearsTable years={p.years} caption={`${name} model years`} />
          <p className="xs muted">{EPA_NOTE}</p>
        </section>}
        <SimilarModels items={p.similar_models} title={`Similar to the ${name}`} />
      </div>
      <div className="wrap vp-body"><p className="small" data-testid="vp-buy-link"><Link prefetch={false} className="link" href={`/buy${p.path.slice(5)}`}>Buying a {name}? Specs, recalls and what to check</Link></p></div>
      <InventoryBlock inv={p.inventory} labels={labels} name={name} exactLabel={`Our ${name} cars`} sameLabel="" />
      <div className="wrap vp-body"><Questions items={faq.map((q) => ({ question: F(q.question), answer: F(q.answer) }))} title={`Renting a ${name}`} /></div>
    </div>
  );
}

// ---------------------------------------------------------------- year
export async function yearMeta(p: YearPage): Promise<Metadata> {
  const t = await getTokens();
  const sp = specs(p.variants, p.settings);
  return vehicleMeta({ title: fit(titleOptions({ make: p.make.name, model: p.model.name, year: p.year }), (x) => fill(x, t), 70), path: p.path, indexable: p.indexable, canonical: p.canonical,
    description: fit(descriptionOptions({ make: p.make.name, model: p.model.name, year: p.year, use: ratingRange(sp), trims: p.trims.map((x) => x.name), cars: p.inventory.exact.length }), (x) => fill(x, t), 170, 70),
    image: standIn({ path: p.path, group: p.body_group, vclass: p.vclass, model: p.model.name }), imageAlt: `${p.year} ${p.make.name} ${p.model.name} studio image` });
}

export async function YearView({ p }: { p: YearPage }) {
  const [t, labels] = await Promise.all([getTokens(), labelsOf()]);
  const name = `${p.year} ${p.make.name} ${p.model.name}`;
  const modelPath = `/cars/${p.make.slug}/${p.model.slug}`;
  const trail: Trail = [['Home', '/'], ['Fleet', '/cars'], [p.make.name, `/cars/${p.make.slug}`], [p.model.name, modelPath], [String(p.year)]];
  const img = standIn({ path: p.path, group: p.body_group, vclass: p.vclass, model: p.model.name });
  const sp = specs(p.variants, p.settings);
  const prevSp = p.prev ? specs(p.prev.variants, p.settings) : [];
  const changes = yearChanges({ year: p.year, cur: sp, prevYear: p.prev?.year ?? null, prev: prevSp, curTrims: p.trims.map((x) => x.name), prevTrims: p.prev?.trims ?? [] });
  const cheapest = sp.filter((x) => x.cost100 !== null)[0];
  const lead = `${sp.length ? `The ${name} came with ${sp.length === 1 ? `one powertrain, the ${ptName(sp[0]!)}` : `${sp.length} powertrains`}, rated ${ratingRange(sp)} combined.` : `The ${name}.`}${p.trims.length ? ` In Canada it was sold as the ${list(p.trims.map((x) => x.name))}.` : ''}${p.vclass ? ` EPA class: ${lower(p.vclass)}.` : ''}`;
  const seats = p.inventory.exact.find((c) => c.seats)?.seats ?? null;
  const faq = rentalFaq({ name, cars: p.inventory.exact.length, similar: p.inventory.similar.length, ev: cheapest?.fuel === 'electric',
    cost100: cheapest ? dollars(cheapest.cost100) : null, cheapestUse: cheapest ? `${ratingText(cheapest)} (${ptName(cheapest)})` : undefined, basis: cheapest ? priceBasis(cheapest, p.settings) : undefined });
  const F = (x: string) => fill(x, t);
  return (
    <div className="p-vehicle" data-page="vehicle-year">
      <JsonLd graph={[breadcrumbLd(trail, p.path), productLd({ name, make: p.make.name, model: p.model.name, year: p.year, path: p.path, image: img, description: lead, inv: p.inventory,
        fuel: sp[0] ? fuelWord(sp[0].fuel) : undefined, body: p.vclass }), faqLd(faq.map((q) => ({ question: F(q.question), answer: F(q.answer) })))]} />
      <VehicleHead trail={trail} h1={`Rent a ${name} in ${t.city}`} lead={lead} img={img} alt={`${name} in the studio, a representative image`}
        facts={[['Powertrains', String(sp.length || '')], ['Combined', sp.length ? ratingRange(sp).split(', or')[0]! : ''], ['Trims', String(p.trims.length || '')], ['Our cars', String(p.inventory.exact.length)]].filter(([, v]) => v) as Array<[string, string]>} />
      <div className="wrap vp-body">
        <section className="vp-sec" aria-labelledby="h-specs">
          <h2 className="d3" id="h-specs">{name} specs</h2>
          <SpecsTable sp={sp} seats={seats} caption={`${name} powertrains`} />
        </section>
        <CostBlock sp={sp} s={p.settings} name={name} />
        {p.trims.length > 0 && <section className="vp-sec" aria-labelledby="h-trims">
          <h2 className="d3" id="h-trims">{p.year} {p.model.name} trims in Canada</h2>
          <ul className="hub-grid" data-testid="vp-trims">{p.trims.map((x) => { const s1 = specs(p.variants, p.settings, x.variant_ids); return (
            <li key={x.slug}><Link prefetch={false} className="hub-card" href={x.path}><h3>{x.name}</h3><p>{s1.length ? `${list([...new Set(s1.map((y) => y.engine))])}, ${ratingRange(s1)}` : 'Not rated by EPA'}</p></Link></li>); })}</ul>
        </section>}
        {changes.length > 0 && <section className="vp-sec" aria-labelledby="h-changed" data-testid="vp-changes">
          <h2 className="d3" id="h-changed">What changed for {p.year}</h2>
          <ul className="featlist">{changes.map((c) => <li key={c}>{c}</li>)}</ul>
        </section>}
        <section className="vp-sec" aria-labelledby="h-years">
          <h2 className="d3" id="h-years">Other {p.make.name} {p.model.name} years</h2>
          <YearsTable years={p.other_years} current={p.year} caption={`${p.make.name} ${p.model.name} model years`} />
          <p className="xs muted">{EPA_NOTE}</p>
        </section>
        <p className="small"><Link prefetch={false} className="link" href={`/buy${p.path.slice(5)}`}>Buying a {name}? Specs, recalls and what to check</Link></p>
        <SimilarModels items={p.similar_models} title={`Other ${p.year} ${lower(p.vclass) || 'cars'} like it`} />
      </div>
      <InventoryBlock inv={p.inventory} labels={labels} name={name} exactLabel={`Our ${name} cars`} sameLabel={`${p.make.name} ${p.model.name} in other years`} />
      <div className="wrap vp-body"><Questions items={faq.map((q) => ({ question: F(q.question), answer: F(q.answer) }))} title={`Renting the ${name}`} /></div>
    </div>
  );
}

// ---------------------------------------------------------------- trim
export async function trimMeta(p: TrimPage): Promise<Metadata> {
  const t = await getTokens();
  const sp = specs(p.variants, p.settings, p.trim.variant_ids);
  return vehicleMeta({ title: fit(titleOptions({ make: p.make.name, model: p.model.name, year: p.year, trim: p.trim.name }), (x) => fill(x, t), 70), path: p.path, indexable: p.indexable, canonical: p.canonical,
    description: fit(descriptionOptions({ make: p.make.name, model: p.model.name, year: p.year, trim: p.trim.name, use: [list([...new Set(sp.map((x) => x.engine))]), ratingRange(sp)].filter(Boolean).join(', '), cars: p.inventory.exact.length }), (x) => fill(x, t), 170, 70),
    image: standIn({ path: p.path, group: p.body_group, vclass: p.vclass, model: p.model.name }), imageAlt: `${p.year} ${p.make.name} ${p.model.name} ${p.trim.name} studio image` });
}

export async function TrimView({ p }: { p: TrimPage }) {
  const [t, labels, tiers] = await Promise.all([getTokens(), labelsOf(), getTiers()]);
  const name = `${p.year} ${p.make.name} ${p.model.name} ${p.trim.name}`;
  const modelPath = `/cars/${p.make.slug}/${p.model.slug}`;
  const yearPath = `${modelPath}/${p.year}`;
  const trail: Trail = [['Home', '/'], ['Fleet', '/cars'], [p.make.name, `/cars/${p.make.slug}`], [p.model.name, modelPath], [String(p.year), yearPath], [p.trim.name]];
  const img = standIn({ path: p.path, group: p.body_group, vclass: p.vclass, model: p.model.name });
  const sp = specs(p.variants, p.settings, p.trim.variant_ids);
  const diffs = trimDiffs(p.trim, p.siblings, p.variants, p.settings);
  const prevSp = p.prev ? specs(p.prev.variants, p.settings, p.prev.trim_variant_ids ?? undefined) : [];
  const changes = p.prev?.trim_variant_ids ? yearChanges({ year: p.year, cur: sp, prevYear: p.prev.year, prev: prevSp, curTrims: [], prevTrims: [] }) : [];
  const cheapest = sp.filter((x) => x.cost100 !== null)[0];
  const lead = `${sp.length ? `The ${name} has ${sp.length === 1 ? `the ${ptName(sp[0]!)}` : `a choice of ${sp.length} powertrains`}, rated ${ratingRange(sp)} combined.` : `The ${name}.`} ${diffs[0] ?? ''}`.trim();
  const seats = p.inventory.exact.find((c) => c.seats)?.seats ?? null;
  const faq = rentalFaq({ name, cars: p.inventory.exact.length, similar: p.inventory.similar.length + p.inventory.same_model.length, ev: cheapest?.fuel === 'electric',
    cost100: cheapest ? dollars(cheapest.cost100) : null, cheapestUse: cheapest ? `${ratingText(cheapest)} (${ptName(cheapest)})` : undefined, basis: cheapest ? priceBasis(cheapest, p.settings) : undefined });
  const F = (x: string) => fill(x, t);
  return (
    <div className="p-vehicle" data-page="vehicle-trim">
      <JsonLd graph={[breadcrumbLd(trail, p.path), productLd({ name, make: p.make.name, model: p.model.name, year: p.year, trim: p.trim.name, path: p.path, image: img, description: lead, inv: p.inventory,
        fuel: sp[0] ? fuelWord(sp[0].fuel) : undefined, body: p.vclass, extra: vehicleProps(sp, dimsFor(p.dims, p.model.name, p.trim.name), seats) }), faqLd(faq.map((q) => ({ question: F(q.question), answer: F(q.answer) })))]} />
      <VehicleHead trail={trail} h1={`Rent a ${name} in ${t.city}`} lead={lead} img={img} alt={`${name} in the studio, a representative image`}
        facts={[['Engine', sp.length === 1 ? sp[0]!.engine : sp.length ? `${sp.length} choices` : ''], ['Combined', sp.length ? ratingRange(sp).split(', or')[0]! : ''],
          ['Trim', `${p.trim.rank} of ${p.siblings.length}`], ['Our cars', String(p.inventory.exact.length)]].filter(([, v]) => v) as Array<[string, string]>} />
      <div className="wrap vp-body">
        <section className="vp-sec" aria-labelledby="h-specs">
          <h2 className="d3" id="h-specs">{name} specs</h2>
          <SpecsTable sp={sp} seats={seats} caption={`${name} powertrains`} />
        </section>
        <StatsBlock sp={sp} dims={p.dims} model={p.model.name} trim={p.trim.name} name={name} s={p.settings} seats={seats} />
        <CostBlock sp={sp} s={p.settings} name={name} />
        <section className="vp-sec" aria-labelledby="h-diff" data-testid="vp-diffs">
          <h2 className="d3" id="h-diff">How the {p.trim.name} compares with the other {p.year} trims</h2>
          <ul className="featlist">{diffs.map((d) => <li key={d}>{d}</li>)}</ul>
          <div className="table-scroll" tabIndex={0} role="region" aria-label={`${p.year} ${p.model.name} trims`}>
            <table className="data" data-testid="vp-siblings"><caption className="vh">{p.year} {p.make.name} {p.model.name} trims</caption>
              <thead><tr><th scope="col">Trim</th><th scope="col">Engine</th><th scope="col">Drive</th><th scope="col">Combined</th></tr></thead>
              <tbody>{p.siblings.map((x) => { const s1 = specs(p.variants, p.settings, x.variant_ids); return (
                <tr key={x.slug} aria-current={x.slug === p.trim.slug ? 'page' : undefined}>
                  <th scope="row">{x.slug === p.trim.slug ? <b>{x.name}</b> : <Link prefetch={false} className="link" href={x.path}>{x.name}</Link>}</th>
                  <td>{list([...new Set(s1.map((y) => y.engine))]) || 'Not rated'}</td><td>{list([...new Set(s1.map((y) => y.drive).filter(Boolean) as string[])])}</td><td>{ratingRange(s1)}</td></tr>); })}</tbody>
            </table>
          </div>
        </section>
        {(changes.length > 0 || p.trim_years.length > 1) && <section className="vp-sec" aria-labelledby="h-trimyears">
          <h2 className="d3" id="h-trimyears">The {p.model.name} {p.trim.name} in other years</h2>
          {changes.length > 0 && <ul className="featlist">{changes.map((c) => <li key={c}>{c}</li>)}</ul>}
          {p.trim_years.length > 1 && <ul className="chips">{p.trim_years.map((y) => <li key={y.year}>{y.year === p.year ? <span className="chip" aria-current="page">{y.year}</span> : <Link prefetch={false} className="chip" href={y.path}>{y.year}</Link>}</li>)}</ul>}
        </section>}
        <section className="vp-sec" aria-labelledby="h-years">
          <h2 className="d3" id="h-years">Every {p.make.name} {p.model.name} year</h2>
          <YearsTable years={p.other_years} current={p.year} caption={`${p.make.name} ${p.model.name} model years`} />
          <p className="xs muted">{EPA_NOTE}</p>
        </section>
        <TierLinks base={p.path} tiers={tiers} name={name} />
        <p className="small"><Link prefetch={false} className="link" href={`/buy${p.path.slice(5)}`}>Buying a {name}? Specs, recalls and what to check</Link></p>
        <TierLinks base={p.path} tiers={tiers} name={name} />
        <p className="small"><Link prefetch={false} className="link" href={`/buy${p.path.slice(5)}`}>Buying a {name}? Specs, recalls and what to check</Link></p>
        <SimilarModels items={p.similar_models} title={`Other ${p.year} ${lower(p.vclass) || 'cars'} like it`} />
      </div>
      <InventoryBlock inv={p.inventory} labels={labels} name={name} exactLabel={`Our ${name} cars`} sameLabel={`Other ${p.make.name} ${p.model.name} cars we have`} />
      <div className="wrap vp-body"><Questions items={faq.map((q) => ({ question: F(q.question), answer: F(q.answer) }))} title={`Renting the ${name}`} /></div>
    </div>
  );
}
