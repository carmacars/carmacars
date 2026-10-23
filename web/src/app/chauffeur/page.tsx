import Link from 'next/link';
import { AnswerBlock } from '@/components/AnswerBlock';
import { PageHead } from '@/components/Blocks';
import { JsonLd } from '@/components/JsonLd';
import type { ChauffeurServices } from '@/features/chauffeur/schema';
import { breadcrumbLd, type Trail, seoMeta } from '@/features/seo/meta';
import { rpc } from '@/lib/db/repo';
import { money } from '@/lib/format';
import { fill, getSettings, getTokens, siteUrl } from '@/lib/site';

export const revalidate = 3600;
const trail: Trail = [['Home', '/'], ['Chauffeur service']];
const load = async () => (await rpc('chauffeur_services', {})) as unknown as ChauffeurServices;

export async function generateMetadata() {
  const [t, c] = await Promise.all([getTokens(), load()]);
  const low = Math.min(...c.vehicles.map((v) => v.rate_3plus_cents));
  return seoMeta({ title: fill('Chauffeur service in {{city}}, by the hour | {{brand}}', t), path: '/chauffeur',
    description: fill(`A professional driver and a luxury car or van by the hour in {{city}}: Rolls-Royce, Maybach, Escalade. From ${money(Number.isFinite(low) ? low : 0)} an hour, 2 hours minimum.`, t) });
}

// The chauffeur service (migration 0093): every vehicle with its hourly rates (2 hours, and 3 hours or more), the
// rentals a vehicle also is, and the request form. JSON-LD: the Service with one Offer per vehicle.
export default async function Chauffeur() {
  const [s, t, c] = await Promise.all([getSettings(), getTokens(), load()]);
  const url = `${siteUrl()}/chauffeur`;
  const ld = {
    '@type': 'Service', '@id': `${url}#service`, name: 'Chauffeur service', serviceType: 'Chauffeur service', url,
    description: fill('A professional driver and a luxury car or van by the hour in {{city}} and the area, 2 hours minimum.', t),
    provider: { '@id': `${siteUrl()}/#business` }, areaServed: { '@type': 'City', name: s.city },
    offers: c.vehicles.map((v) => ({
      '@type': 'Offer', name: v.name, url: `${siteUrl()}/chauffeur/request?vehicle=${v.slug}`, priceCurrency: 'CAD', price: (v.rate_3plus_cents / 100).toFixed(2),
      priceSpecification: [
        { '@type': 'UnitPriceSpecification', price: (v.rate_2h_cents / 100).toFixed(2), priceCurrency: 'CAD', unitCode: 'HUR', unitText: 'per hour, 2 hours', referenceQuantity: { '@type': 'QuantitativeValue', value: 2, unitCode: 'HUR' }, valueAddedTaxIncluded: false },
        { '@type': 'UnitPriceSpecification', price: (v.rate_3plus_cents / 100).toFixed(2), priceCurrency: 'CAD', unitCode: 'HUR', unitText: 'per hour, 3 hours or more', valueAddedTaxIncluded: false }
      ],
      eligibleQuantity: { '@type': 'QuantitativeValue', minValue: 2, unitCode: 'HUR' }
    }))
  };
  return (
    <div className="p-chauffeur" data-page="chauffeur">
      <JsonLd graph={[breadcrumbLd(trail, '/chauffeur'), ld]} />
      <PageHead trail={trail} h1="A driver, by the hour." lead={fill('A professional chauffeur and a luxury car or van for weddings, airport runs, nights out and business in {{city}}. Two hours minimum.', t)} />
      {c.vehicles.length > 0 && (() => {
        const low = Math.min(...c.vehicles.map((v) => v.rate_3plus_cents));
        return <AnswerBlock lead={`${s.brand_name} offers chauffeur service in ${s.city}: a professional driver with a luxury car or van, from ${money(low)} an hour before HST, ${c.min_hours} hours minimum. Request online with no payment${s.phone_display ? ` or call ${s.phone_display}` : ''}.`}
          rows={[['Vehicles', c.vehicles.map((v) => `${v.name} (up to ${v.passengers})`).join(', ')], ['Price from', `${money(low)} an hour for 3 hours or more, before HST`], ['Minimum', `${c.min_hours} hours`],
            ['How to book', 'Send a request with the date, time and route. We confirm the vehicle and the price before you pay.'], ...(s.phone_display ? [['Phone', s.phone_display] as [string, string]] : [])]} />;
      })()}
      <section className="section" aria-labelledby="ch-list">
        <div className="wrap stack-lg">
          <div className="section-head"><h2 className="d2" id="ch-list">Vehicles and hourly rates</h2>
            <Link className="btn btn--primary" href="/chauffeur/request">Request a chauffeur</Link></div>
          <ul className="ch-grid" data-testid="chauffeur-vehicles">
            {c.vehicles.map((v) => (
              <li key={v.id} className="ch-card" data-testid={`chauffeur-${v.slug}`}>
                <h3 className="d4">{v.name}</h3>
                <p className="small muted">Up to {v.passengers} passengers{v.kind === 'chauffeur_rental' && v.rentals.some((r) => r.path) ? ', also for rent' : ', with a chauffeur'}</p>
                <table className="spec spec--num"><tbody>
                  <tr><th scope="row">2 hours</th><td><span className="num">{money(v.rate_2h_cents)}</span> an hour</td></tr>
                  <tr><th scope="row">3 hours or more</th><td><span className="num">{money(v.rate_3plus_cents)}</span> an hour</td></tr>
                </tbody></table>
                {v.rentals.some((r) => r.path) && <p className="small">Drive it yourself: {v.rentals.filter((r) => r.path).map((r, i) => <span key={r.vehicle_id}>{i ? ', ' : ''}<Link className="link" href={r.path!}>{r.name}</Link></span>)}</p>}
                <p><Link className="btn btn--ghost btn--sm" href={`/chauffeur/request?vehicle=${v.slug}`} aria-label={`Request the ${v.name} with a chauffeur`}>Request this vehicle</Link></p>
              </li>))}
          </ul>
          <p className="small muted measure">Rates are before HST. Guideline rates; final price confirmed after review. Two hours are charged at the 2-hour rate, three hours or more at the 3+ hour rate for every hour.</p>
        </div>
      </section>
      <section className="section on-grey" aria-labelledby="ch-how">
        <div className="wrap grid">
          <div className="c-5"><h2 className="d2" id="ch-how">How it works</h2></div>
          <div className="c-7"><ol className="seq">
            <li><div><h3>Send a request</h3><p>The vehicle, the date and start time, the hours, where we pick you up and drop you off. No payment to ask.</p></div></li>
            <li><div><h3>We confirm and quote</h3><p>We check the vehicle and the driver for your time and send the quote by email.</p></div></li>
            <li><div><h3>Your chauffeur arrives</h3><p>On time, at the pickup address, for the hours you booked. Extra time is added by the hour.</p></div></li>
          </ol>
          <p><Link className="btn btn--primary btn--lg" href="/chauffeur/request">Request a chauffeur</Link></p></div>
        </div>
      </section>
    </div>
  );
}
