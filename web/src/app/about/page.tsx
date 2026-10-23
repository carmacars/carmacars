import Link from 'next/link';
import { AnswerBlock } from '@/components/AnswerBlock';
import { PageHead } from '@/components/Blocks';
import { JsonLd } from '@/components/JsonLd';
import { businessLd } from '@/features/seo/business';
import { getBusinessFacts } from '@/features/seo/business-data';
import { getEntityFacts } from '@/features/seo/facts';
import { keyFacts, summary } from '@/features/seo/llms';
import { breadcrumbLd, type Trail, seoMeta } from '@/features/seo/meta';
import { money } from '@/lib/format';
import { getSettings, siteUrl } from '@/lib/site';

// /about (docs/changes/2026-10-23-ai-search.md): the facts about CarmaCars in one place that people and AI answer
// engines can cite: name, address and phone, what we do, where, prices from the real cars, how to book, the policies.
// Every value is read from the database (features/seo/facts.ts); /llms-full.txt is the same facts as Markdown.
export const revalidate = 3600;
const trail: Trail = [['Home', '/'], ['About']];

export async function generateMetadata() {
  const f = await getEntityFacts();
  return seoMeta({ title: `About ${f.name}: Facts, Prices and Contact | Car Rental ${f.city}`, path: '/about',
    description: summary(f).slice(0, 160) });
}

export default async function About() {
  const [f, s, bf] = await Promise.all([getEntityFacts(), getSettings(), getBusinessFacts()]);
  const url = `${siteUrl()}/about`;
  const page = { '@type': 'AboutPage', '@id': `${url}#page`, url, name: `About ${f.name}`, about: { '@id': `${siteUrl()}/#business` }, inLanguage: 'en-CA',
    ...(f.updated ? { dateModified: f.updated } : {}), isPartOf: { '@id': `${siteUrl()}/#website` } };
  return (
    <div className="p-about" data-page="about">
      <JsonLd graph={[breadcrumbLd(trail, '/about'), page, businessLd(s, siteUrl(), { areas: bf.areas, price: bf.price })]} />
      <PageHead trail={trail} h1={`About ${f.name}`} lead={f.tagline ? `${f.tagline} The facts, in one place.` : 'The facts, in one place.'} />
      <AnswerBlock title="Who we are" lead={summary(f)} rows={keyFacts(f)} updated={f.updated} />
      <section className="section--tight" aria-labelledby="h-contact"><div className="wrap stack">
        <h2 className="d2" id="h-contact">Name, address and phone</h2>
        <table className="spec measure"><tbody>
          <tr><th scope="row">Business</th><td>{f.name}</td></tr>
          <tr><th scope="row">Address</th><td>{f.address}</td></tr>
          {f.phone && <tr><th scope="row">Phone</th><td>{f.phoneE164 ? <a className="link" href={`tel:${f.phoneE164}`}>{f.phone}</a> : f.phone}</td></tr>}
          {f.email && <tr><th scope="row">Email</th><td><a className="link" href={`mailto:${f.email}`}>{f.email}</a></td></tr>}
          {f.hours && <tr><th scope="row">Hours</th><td>{f.hours}</td></tr>}
          <tr><th scope="row">Area served</th><td>{f.serviceArea}</td></tr>
          <tr><th scope="row">Website</th><td>{siteUrl().replace(/^https?:\/\//, '')}</td></tr>
        </tbody></table>
      </div></section>
      <section className="section--tight on-grey" aria-labelledby="h-fleet"><div className="wrap stack">
        <h2 className="d2" id="h-fleet">Fleet and prices</h2>
        {f.fleet.realCars > 0 ? (
          <table className="spec measure"><tbody>
            <tr><th scope="row">Cars listed</th><td className="num">{f.fleet.realCars}</td></tr>
            {f.fleet.classes.map((c) => <tr key={c.label}><th scope="row">{c.label}</th><td>{c.count} {c.count === 1 ? 'car' : 'cars'}, from <span className="num">{money(c.fromDailyCents)}</span> a day</td></tr>)}
            {f.fleet.fromWeeklyCents && <tr><th scope="row">By the week</th><td>From <span className="num">{money(f.fleet.fromWeeklyCents)}</span></td></tr>}
            {f.fleet.fromMonthlyCents && <tr><th scope="row">{f.policy.maxDays} days</th><td>From <span className="num">{money(f.fleet.fromMonthlyCents)}</span></td></tr>}
            {f.chauffeurFromCents && <tr><th scope="row">Chauffeur</th><td>From <span className="num">{money(f.chauffeurFromCents)}</span> an hour{f.chauffeurMinHours ? `, ${f.chauffeurMinHours} hours minimum` : ''}</td></tr>}
          </tbody></table>
        ) : <p className="measure">Our first cars are being listed. Each car shows its own rates and deposit on its page.</p>}
        <p className="small muted measure">Prices in Canadian dollars, before HST ({f.policy.hst}). <Link className="link" href="/cars">See every car with its live rates</Link>.</p>
      </div></section>
      <section className="section--tight" aria-labelledby="h-rent"><div className="wrap stack">
        <h2 className="d2" id="h-rent">Renting</h2>
        <table className="spec measure"><tbody>
          <tr><th scope="row">Drivers</th><td>{f.drivers.minAge} and up, {f.drivers.licence}</td></tr>
          <tr><th scope="row">Booking length</th><td>1 to {f.policy.maxDays} days</td></tr>
          <tr><th scope="row">Deposit</th><td>{f.policy.deposits}, shown on each car&apos;s page</td></tr>
          <tr><th scope="row">Cancellation</th><td>{f.policy.cancellation}</td></tr>
          <tr><th scope="row">To book</th><td>Choose a car and send a request, with no payment. You pay once we confirm the car and the price.</td></tr>
        </tbody></table>
      </div></section>
      <section className="section--tight on-grey" aria-labelledby="h-services"><div className="wrap stack">
        <h2 className="d2" id="h-services">What we do</h2>
        <ul className="linklist">{f.services.map((l) => <li key={l.path}><Link prefetch={false} className="link" href={l.path}>{l.name}</Link>{l.note ? <span className="muted">: {l.note}</span> : null}</li>)}</ul>
        {f.locations.length > 0 && <><h3 className="d4">Places we deliver to</h3>
          <ul className="linklist">{f.locations.map((l) => <li key={l.path}><Link prefetch={false} className="link" href={l.path}>{l.name}</Link></li>)}</ul></>}
        <p className="small muted measure">The same facts as plain text for AI assistants: <a className="link" href="/llms-full.txt">llms-full.txt</a>.</p>
      </div></section>
    </div>
  );
}
