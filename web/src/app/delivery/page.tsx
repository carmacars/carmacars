import Link from 'next/link';
import { Crumbs } from '@/components/Crumbs';
import { CtaBand } from '@/components/Blocks';
import { JsonLd } from '@/components/JsonLd';
import { SlotPicture } from '@/components/Picture';
import { breadcrumbLd, pageMeta, type Trail } from '@/features/seo/meta';
import { money } from '@/lib/format';
import { fill, getFleet, getTokens, slotPhoto } from '@/lib/site';

export const revalidate = 3600;
const trail: Trail = [['Home', '/'], ['Delivery']];

export async function generateMetadata() {
  const t = await getTokens();
  return pageMeta({ title: fill('Car rental delivery in {{city}} | {{brand}}', t), path: '/delivery',
    description: fill('{{brand}} delivers rental cars anywhere, including your home, office, hotel and {{city}} airports, and picks them up at the end. From {{delMin}} each way plus distance.', t) });
}

export default async function Delivery() {
  const [t, fleet, hero] = await Promise.all([getTokens(), getFleet(), slotPhoto('delivery.hero')]);
  const F = (x: string) => fill(x, t);
  const groups = [...new Set(fleet.map((c) => c.delivery_fee_cents))].sort((a, b) => a - b);
  return (
    <div className="p-delivery">
      <JsonLd graph={[breadcrumbLd(trail, '/delivery')]} />
      <section className="band band--hero on-dark">
        <div className="band__media photo fx-drift"><SlotPicture p={hero} eager /></div>
        <div className="wrap band__inner"><div className="band__copy stack">
          <Crumbs trail={trail} />
          <h1 className="d1">The car comes to you.</h1>
          <p className="lead">{F('Anywhere: homes, offices, hotels and {{airports}}, day or night. We can collect the car at the end too. Each way costs the car’s delivery fee plus the distance from our location.')}</p>
          <p><Link className="btn btn--primary btn--lg" href="/cars?mode=delivery">Find a car for delivery</Link></p>
        </div></div>
      </section>
      <section className="section" aria-labelledby="dl-how">
        <div className="wrap grid">
          <div className="c-5"><div className="how__sticky stack"><h2 className="d1" id="dl-how">How delivery works</h2><p className="lead">The same handover as collecting it yourself, at your door.</p></div></div>
          <div className="c-7 how__steps"><span className="how__line fx-grow-y" aria-hidden="true"></span>
            <ol className="seq">
              <li><div><h3>Add your address to the request</h3><p>Choose delivery, pickup at the end, or both, and start typing the address. We price the distance in your offer.</p></div></li>
              <li><div><h3>We message you the day before</h3><p>A reminder with the time, the place and what to bring: your original licence and the card you paid with.</p></div></li>
              <li><div><h3>Handover at your door</h3><p>{F('The deposit is taken about {{depLead}} before. At the door we check your licence and card, then walk around the car with you and photograph it. You both sign the condition report.')}</p></div></li>
              <li><div><h3>At the end, we come back</h3><p>If you chose pickup, meet our driver with the car and all the keys. The return inspection happens there, with you.</p></div></li>
            </ol>
          </div>
        </div>
      </section>
      <section className="section on-grey" aria-labelledby="dl-fee">
        <div className="wrap grid">
          <div className="c-4 stack"><h2 className="d2" id="dl-fee">What it costs</h2><p className="muted">The car’s fee plus distance for delivery, the same again for pickup at the end. Before HST. Collecting and returning the car yourself, at our location or the car owner’s, is free.</p></div>
          <div className="c-8 stack-lg">
            <div className="table-scroll" tabIndex={0} role="region" aria-label="Delivery fee by car">
              <table className="data"><thead><tr><th scope="col">Each way, plus distance</th><th scope="col">Cars</th></tr></thead><tbody>
                {groups.map((g) => <tr key={g}><td className="num strong">{money(g)}</td><td>{fleet.filter((c) => c.delivery_fee_cents === g).map((c, i) => <span key={c.slug}>{i > 0 && ', '}<Link className="link" href={`/cars/${c.slug}`}>{c.make} {c.model}</Link></span>)}</td></tr>)}
              </tbody></table>
            </div>
            <table className="spec"><tbody>
              <tr><th scope="row">Who receives the car</th><td>The renter, in person. We cannot leave a car with someone else.</td></tr>
              <tr><th scope="row">Where</th><td>Anywhere. Tell us the address in your request and the distance is priced in your offer, before you pay.</td></tr>
              <tr><th scope="row">Airports</th><td>{F('{{airports}}. Add your flight number to the request. An airport surcharge may apply.')}</td></tr>
              <tr><th scope="row">When</th><td>{F('Any time, day or night, with at least {{notice}}’ notice')}</td></tr>
              <tr><th scope="row">Cancelling</th><td>Delivery and pickup fees are refunded on the same tiers as the rest of the booking</td></tr>
              <tr><th scope="row">Leaving it somewhere else</th><td>A car left anywhere other than the agreed place has not been returned</td></tr>
            </tbody></table>
          </div>
        </div>
      </section>
      <CtaBand h="Delivery is one tick in the request." p="Pick the car first. The delivery fee is on its page." />
    </div>
  );
}
