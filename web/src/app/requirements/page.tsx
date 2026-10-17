import Link from 'next/link';
import { CtaBand, PageHead } from '@/components/Blocks';
import { JsonLd } from '@/components/JsonLd';
import { breadcrumbLd, type Trail, seoMeta } from '@/features/seo/meta';
import { money } from '@/lib/format';
import { fill, getFacts, getFleet, getSettings, getTokens, listItems } from '@/lib/site';

export const revalidate = 3600;
const trail: Trail = [['Home', '/'], ['Requirements and coverage']];
type Row = { label: string; text: string };

export async function generateMetadata() {
  const t = await getTokens();
  return seoMeta({ title: fill('Rental requirements and coverage | {{brand}}, {{city}}', t), path: '/requirements',
    description: fill('Who can rent from {{brand}}: age {{minAge}} and up with an Ontario {{licence}} licence. Three coverage options, deposits from {{depMin}} before pickup, and every fee.', t) });
}

export default async function Requirements() {
  const [s, f, t, fleet, rows] = await Promise.all([getSettings(), getFacts(), getTokens(), getFleet(), listItems<Row>('home.requirements')]);
  const F = (x: string) => fill(x, t);
  const tel = s.roadside_phone ? <a className="link" href={`tel:${s.roadside_phone}`}>{s.roadside_phone_display}</a> : null;
  const fees: [string, string, string][] = [
    ['Delivery, pickup', 'Each way, if you choose it', 'The car’s fee, from {{delMin}}, plus distance'], ['Airport delivery or pickup', '{{airports}}', 'As delivery; a surcharge may apply'],
    ['Additional driver', 'Each driver, each day', '{{addDrvPct}} of the daily rate'], ['Young driver', 'Ages {{youngA}}, each day', 'Usually {{ydA}}'], ['Young driver', 'Ages {{youngB}}, each day', 'Usually {{ydB}}'],
    ['Winter tires', 'On request', '{{winter}} a day, up to {{winterCap}}'], ['Baby seat', 'Each seat', '{{baby}} a day, up to {{babyCap}}'],
    ['Extra kilometres', 'Over your allowance', '{{overMin}} to {{overMax}} per km, set per car'], ['Late return', 'More than {{grace}} late', '{{lateHr}} an hour, plus the extra day'],
    ['Fuel', 'Less fuel than at pickup', 'Pump price + {{fuelPct}}, + {{fuelFee}}'], ['Recharging', 'Less charge than at pickup', '{{evPer}} per 10% of battery, + {{fuelFee}}'],
    ['Cleaning', 'More than a standard clean', '{{clean}}; {{cleanHeavy}} if heavy'], ['Pet cleaning', 'Hair, odour or soiling', '{{pet}}'], ['Smoking', 'Evidence of smoking or vaping', '{{smoke}}'],
    ['Lost key or fob', 'Each one', 'Replacement cost + {{keyFee}}'], ['Tolls', 'Each toll invoice, on top of the toll', '{{tollFee}}'],
    ['Tickets, fines, towing, impound', 'Each item, on top of its amount', '{{ticketFee}}'], ['Declined payment', 'Once per declined charge', '{{declined}}']
  ];
  return (
    <div className="p-req">
      <JsonLd graph={[breadcrumbLd(trail, '/requirements')]} />
      <PageHead trail={trail} h1="What you need, and how you’re covered." lead="The rules are short. Here they are in full, with the numbers." />
      <nav className="car-nav" aria-label="On this page"><div className="wrap"><ul>
        {[['drivers', 'Drivers'], ['coverage', 'Coverage'], ['damage', 'Damage'], ['deposit', 'Deposit'], ['fees', 'Fees'], ['rules', 'Rules of the road']].map(([id, l]) => <li key={id}><a href={`#${id}`}>{l}</a></li>)}
      </ul></div></nav>
      <section className="section" id="drivers" aria-labelledby="rq-d">
        <div className="wrap grid">
          <div className="c-4"><h2 className="d2" id="rq-d">Drivers</h2></div>
          <div className="c-8 stack-lg">
            <table className="spec"><tbody>
              {rows.slice(0, 3).map((r) => <tr key={r.label}><th scope="row">{r.label}</th><td>{F(r.text)}</td></tr>)}
              <tr><th scope="row">Identity check</th><td>Before pickup, each driver sends a photo of their licence, front and back, and a selfie holding it. If we cannot verify a driver, we refund what you paid.</td></tr>
              <tr><th scope="row">Additional drivers</th><td>{F('{{addDrvPct}} of the car’s daily rate, a day, for each one, with no maximum. Each one meets the same rules, is verified, and signs the agreement.')}</td></tr>
              <tr><th scope="row">At pickup</th><td>Your original licence and the physical card you paid with. We hand the car only to the renter, in person.</td></tr>
            </tbody></table>
            <div className="table-scroll" tabIndex={0} role="region" aria-label="Young driver fees">
              <table className="data data--min"><caption>Young driver fees, by age at pickup</caption>
                <thead><tr><th scope="col">Age</th><th scope="col">Which cars</th><th scope="col" className="r">Usual fee per day</th><th scope="col" className="r">Most per rental</th></tr></thead>
                <tbody>
                  <tr><td>{t.youngA}</td><td>Any car</td><td className="r">{t.ydA}</td><td className="r">No maximum</td></tr>
                  <tr><td>{t.youngB}</td><td>Any car</td><td className="r">{t.ydB}</td><td className="r">No maximum</td></tr>
                  <tr><td>{t.fullAge} and over</td><td>Any car</td><td className="r">None</td><td className="r">None</td></tr>
                </tbody>
              </table>
            </div>
            <p className="small muted">Some cars set their own young driver fee. It is on the car’s page and in your estimate.</p>
          </div>
        </div>
      </section>
      <section className="section on-grey" id="coverage" aria-labelledby="rq-c">
        <div className="wrap grid">
          <div className="c-4 stack"><h2 className="d2" id="rq-c">Coverage</h2><p className="muted">Liability is included. Damage to the car is on you, so you need one of three options in place before we release it.</p></div>
          <div className="c-8 stack-lg">
            <div className="alert alert--ok"><span className="alert__title">Included in every rate</span><span>Third-party liability coverage at the minimum limits Ontario law requires, and basic 24-hour roadside assistance for mechanical breakdown{tel ? <>: call {tel}</> : ''}. Liability coverage does not cover damage to the rental car or your belongings.</span></div>
            <div className="table-scroll" tabIndex={0} role="region" aria-label="Coverage options compared">
              <table className="data cov-table"><thead><tr><th scope="col">Option</th><th scope="col">What it is</th><th scope="col">What we need from you</th><th scope="col">What we check</th></tr></thead><tbody>
                <tr><th scope="row">1. OPCF 27</th><td>Rental vehicle coverage on your own active auto policy</td><td>The policy page or an insurer letter showing OPCF 27</td><td>It is active to your return date and covers this car and every driver</td></tr>
                <tr><th scope="row">2. Credit card</th><td>Rental car coverage that comes with your credit card</td><td>The card’s benefits certificate</td><td>The same card pays for the rental, and the benefit covers this class of car and the length of the trip</td></tr>
                <tr><th scope="row">3. Protection Plan</th><td>The {s.brand_name} Protection Plan, added to your booking. A third-party provider supplies it on its own terms</td><td>Payment for it. We send the provider’s terms before you buy.</td><td>We activate it and confirm. Priced in your offer, by car and driver age.</td></tr>
              </tbody></table>
            </div>
            <p className="small muted measure">For options 1 and 2 it is your job to check that the coverage really applies to the car, the rental and every driver. No confirmed option at pickup counts as cancelling at that moment. {s.brand_name} is not an insurer.</p>
          </div>
        </div>
      </section>
      <section className="section" id="damage" aria-labelledby="rq-dm">
        <div className="wrap grid">
          <div className="c-4"><h2 className="d2" id="rq-dm">If the car is damaged</h2></div>
          <div className="c-8 stack-lg">
            <div className="twofacts">
              <div><p className="twofacts__n">{F('Under {{deductible}}')}</p><h3>billed at cost</h3><p className="muted small">{F('You pay the repair estimate or invoice from our approved shop, plus towing, storage and loss of use if any, and a {{adminOther}} administration fee.')}</p></div>
              <div><p className="twofacts__n">{F('{{deductible}} or more')}</p><h3>you pay the deductible</h3><p className="muted small">{F('We claim on our fleet policy and bill you the {{deductible}} deductible and a {{adminClaim}} administration fee. You then claim that back from your coverage option.')}</p></div>
            </div>
            <p className="measure">You are responsible for damage during your rental whoever is at fault, except mechanical failure you did not cause. The limit above does not apply if the insurer denies the claim because of an unapproved driver, impaired driving, a prohibited use or false information.</p>
            <h3 className="d4">After an accident, theft or vandalism</h3>
            <ol className="ticks ticks--n">
              <li>Call 911 if anyone is hurt. Report to police or a Collision Reporting Centre where the law requires, and always for theft.</li>
              <li>Call our 24-hour line{tel ? <>, {tel},</> : ''} as soon as it is safe, and within {t.callHours} hours.</li>
              <li>Get everyone’s details, take photos, and do not admit fault or settle.</li>
              <li>{F('Send us a written report, your photos and all the keys within {{reportHours}} hours.')}</li>
            </ol>
          </div>
        </div>
      </section>
      <section className="section on-grey" id="deposit" aria-labelledby="rq-dp">
        <div className="wrap grid">
          <div className="c-4"><h2 className="d2" id="rq-dp">Deposit</h2></div>
          <div className="c-8 stack-lg">
            <div className="table-scroll" tabIndex={0} role="region" aria-label="Deposit by car">
              <table className="data"><thead><tr><th scope="col" className="r">Deposit</th><th scope="col">Cars with this deposit</th></tr></thead><tbody>
                {f.deposit_tiers_cents.map((tier) => {
                  const cars = fleet.filter((c) => c.deposit_cents === tier);
                  return <tr key={tier}><td className="r num">{money(tier)}</td><td>{cars.length ? cars.map((c, i) => <span key={c.slug}>{i > 0 && ', '}<Link className="link" href={`/cars/${c.slug}`}>{c.make} {c.model}</Link></span>) : 'None right now'}</td></tr>;
                })}
              </tbody></table>
            </div>
            <table className="spec"><tbody>
              <tr><th scope="row">When</th><td>{F('About {{depLead}} before pickup. Never at request or booking.')}</td></tr>
              <tr><th scope="row">How</th><td>{F('A card hold for rentals of {{holdDays}} days or less. Charged, then refunded, for longer rentals.')}</td></tr>
              <tr><th scope="row">Back to you</th><td>{F('The balance within {{releaseDays}} after you return the car')}</td></tr>
              <tr><th scope="row">Held back</th><td>{F('Only the amount expected for an open toll, ticket or claim, for up to {{holdbackDays}}')}</td></tr>
              <tr><th scope="row">Worth knowing</th><td>The deposit secures what you owe. It is not a cap on it.</td></tr>
            </tbody></table>
          </div>
        </div>
      </section>
      <section className="section" id="fees" aria-labelledby="rq-f">
        <div className="wrap grid">
          <div className="c-4 stack"><h2 className="d2" id="rq-f">Fees you might meet</h2><p className="muted">Standard amounts, before HST. The amounts in your own rental agreement are the ones that apply.</p></div>
          <div className="c-8"><div className="table-scroll" tabIndex={0} role="region" aria-label="Schedule of fees">
            <table className="data"><thead><tr><th scope="col">Fee</th><th scope="col">When</th><th scope="col" className="r">Amount</th></tr></thead>
              <tbody>{fees.map(([a, b, c], i) => <tr key={i}><td>{a}</td><td>{F(b)}</td><td className="r">{F(c)}</td></tr>)}</tbody></table>
          </div></div>
        </div>
      </section>
      <section className="section on-dark" id="rules" aria-labelledby="rq-r">
        <div className="wrap grid">
          <div className="c-4"><h2 className="d2" id="rq-r">Rules of the road</h2></div>
          <div className="c-8"><table className="spec"><tbody>
            <tr><th scope="row">Where</th><td>The car stays in Ontario unless we agree in writing first</td></tr>
            <tr><th scope="row">Who drives</th><td>Only you and the additional drivers on the booking</td></tr>
            <tr><th scope="row">Not allowed</th><td>Ride-hailing or delivery work, re-renting, towing, racing or track use, driving off maintained roads</td></tr>
            <tr><th scope="row">Smoking and pets</th><td>No smoking or vaping. Pets need our approval first. Service animals are always welcome.</td></tr>
            <tr><th scope="row">Tracking</th><td>Every car has a GPS tracker that records location for the whole rental. The car’s owner can see its location too.</td></tr>
            <tr><th scope="row">Tolls and tickets</th><td>Yours to pay, including Highway 407 ETR</td></tr>
            <tr><th scope="row">Pickup and return</th><td>{F('Any time, day or night, with at least {{notice}}’ notice. A car needs {{turnaround}} between bookings.')}</td></tr>
            <tr><th scope="row">Longest booking</th><td>{F('{{maxDays}} days. To keep the car longer, you renew with a new booking before the current one ends.')}</td></tr>
          </tbody></table></div>
        </div>
      </section>
      <CtaBand h="Ready when you are." p="Pick a car and send a request. We take it from there." />
    </div>
  );
}
