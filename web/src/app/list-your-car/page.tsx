import { Crumbs } from '@/components/Crumbs';
import { Faq } from '@/components/Faq';
import { JsonLd } from '@/components/JsonLd';
import { SlotPicture } from '@/components/Picture';
import { OwnerForm } from '@/features/forms/OwnerForm';
import { breadcrumbLd, faqLd, type Trail, seoMeta } from '@/features/seo/meta';
import { faqItems, fill, getFacts, getSettings, getTokens, slotPhoto } from '@/lib/site';

export const revalidate = 3600;
const trail: Trail = [['Home', '/'], ['List your car']];

export async function generateMetadata() {
  const t = await getTokens();
  return seoMeta({ title: fill('List your car with {{brand}} | Owner program, {{city}}', t), path: '/list-your-car',
    description: fill('Enrol your car on the {{brand}} rental fleet in {{city}}. We handle renters, insurance on our fleet policy and handovers. Paid on the {{payoutDay}} of each month. No minimum term.', t) });
}

export default async function Owners() {
  const [s, f, t, faq0, hero] = await Promise.all([getSettings(), getFacts(), getTokens(), faqItems('owners.faq'), slotPhoto('owners.hero')]);
  const F = (x: string) => fill(x, t);
  const faq = faq0.map((q) => ({ question: F(q.question), answer: F(q.answer) }));
  return (
    <div className="p-owners">
      <JsonLd graph={[breadcrumbLd(trail, '/list-your-car'), faqLd(faq)]} />
      <section className="band band--hero on-dark">
        <div className="band__media photo fx-drift"><SlotPicture p={hero} eager /></div>
        <div className="wrap band__inner"><div className="band__copy stack">
          <Crumbs trail={trail} />
          <p className="eyebrow">Owner program, {s.city}</p>
          <h1 className="d1">Your car, earning its keep.</h1>
          <p className="lead">{F('List your car with {{brand}}. We find the renters, check their licences, hand over the keys and collect the money. Every handover is photographed, so it comes back the way it left, and you get a statement and a payout every month.')}</p>
          <p className="row"><a className="btn btn--primary btn--lg" href="/list-your-car/apply">Apply to list your car</a><a className="btn btn--ghost btn--lg" href="#apply">Ask us first</a></p>
        </div></div>
      </section>
      <section className="facts on-dark" aria-label="Owner program at a glance"><div className="wrap"><dl className="facts__list">
        <div><dt>Payout</dt><dd>{F('{{payoutDay}} of each month')}</dd></div><div><dt>Minimum term</dt><dd>None</dd></div><div><dt>Notice to leave</dt><dd>{F('{{noticeDays}} days')}</dd></div><div><dt>Security deposit</dt><dd>None</dd></div><div><dt>Your own use</dt><dd>Free when not booked</dd></div>
      </dl></div></section>
      <section className="section" id="how" aria-labelledby="oh-how">
        <div className="wrap grid">
          <div className="c-5"><div className="how__sticky stack"><h2 className="d1" id="oh-how">From your driveway to its first rental</h2><p className="lead">Five steps. We prepare the government forms and come to the registry with you.</p></div></div>
          <div className="c-7 how__steps"><span className="how__line fx-grow-y" aria-hidden="true"></span>
            <ol className="seq">
              <li><div><h3>Tell us about the car</h3><p>{F('Year, make, model, kilometres, and whether it is owned outright, financed or leased. We reply within {{ownerReply}} and set up a call to confirm the fees for your car and what registration will cost you.')}</p></div></li>
              <li><div><h3>Sign the agreements</h3><p>An enrolment agreement and a title agreement, signed online. One agreement covers all your cars. Each car is added with its own schedule.</p></div></li>
              <li><div><h3>One registry visit</h3><p>You get the safety certificate and appraisal your route needs. We fill in the forms, book the visit and attend with you. You pay ServiceOntario directly.</p></div></li>
              <li><div><h3>Tracker and insurance</h3><p>We install a GPS tracker and add the car to our fleet policy. Once we confirm that in writing, you can cancel your own insurance on it.</p></div></li>
              <li><div><h3>Photos, listing, first booking</h3><p>{F('We detail the car, photograph it and publish it within {{listDays}}. Then it is open for requests.')}</p></div></li>
            </ol>
          </div>
        </div>
      </section>
      <section className="section on-grey" aria-labelledby="oh-modes">
        <div className="wrap stack-lg">
          <h2 className="d2" id="oh-modes">Three ways to enrol</h2>
          <div className="table-scroll" tabIndex={0} role="region" aria-labelledby="oh-modes">
            <table className="data modes">
              <thead><tr><td></td><th scope="col">Managed</th><th scope="col">Self-managed</th><th scope="col">Turo only</th></tr></thead>
              <tbody>
                <tr><th scope="row">Who runs the rentals</th><td>{s.brand_name}</td><td>You find renters and set the price. We collect the money.</td><td>{s.brand_name}, on Turo, under our account</td></tr>
                <tr><th scope="row">Revenue share to {s.brand_name}</th><td>A share of owner revenue</td><td>None. You keep 100% of owner revenue.</td><td>A share of the Turo payout</td></tr>
                <tr><th scope="row">Our fleet insurance</th><td>Yes</td><td>Yes</td><td>No. You keep your own comprehensive policy.</td></tr>
                <tr><th scope="row">Monthly insurance and tracker fees</th><td>Yes</td><td>Yes</td><td>No</td></tr>
                <tr><th scope="row">Registration change</th><td>Yes, one registry visit</td><td>Yes, one registry visit</td><td>No. The car stays in your name.</td></tr>
                <tr><th scope="row">GPS tracker</th><td>Yes</td><td>Yes</td><td>No</td></tr>
              </tbody>
            </table>
          </div>
        </div>
      </section>
      <section className="section" aria-labelledby="oh-money">
        <div className="wrap grid">
          <div className="c-6 stack-lg">
            <h2 className="d2" id="oh-money">The money, plainly</h2>
            <table className="spec"><tbody>
              <tr><th scope="row">You earn</th><td>The rental charge and mileage overage fees on your car, less our revenue share</td></tr>
              <tr><th scope="row">{s.brand_name} keeps</th><td>Its revenue share, plus delivery, fuel, cleaning, late return and young driver fees</td></tr>
              <tr><th scope="row">You pay monthly</th><td>{F('An insurance fee and a tracker fee for each car, billed on the {{billDay}}, rented or not')}</td></tr>
              <tr><th scope="row">You pay once</th><td>First and last month’s insurance fee and a tracker install fee. Registry costs go to ServiceOntario, not us.</td></tr>
              <tr><th scope="row">You are paid</th><td>{F('On the {{payoutDay}}, for the month before, with a statement per car')}</td></tr>
              <tr><th scope="row">Referrals</th><td>{F('Send us a new renter and earn {{referralPct}} of the rental charge on their first rental. Not on your own car.')}</td></tr>
            </tbody></table>
          </div>
          <div className="c-5 s-8 stack-lg">
            <h2 className="d2">What it costs you</h2>
            <p className="lead">Fees and our revenue share depend on how many cars you have with us. We confirm them on a call, before you sign anything.</p>
            <ul className="ticks"><li>Every owner’s terms are agreed individually and written into the agreement, car by car</li><li>Self-managed cars pay no revenue share</li><li>Earnings depend on bookings and are not promised</li></ul>
            <p><a className="btn" href="#apply">Apply and book the call</a></p>
          </div>
        </div>
      </section>
      <section className="section on-dark" id="apply" aria-labelledby="oh-apply">
        <div className="wrap grid">
          <div className="c-5 stack"><h2 className="d1" id="oh-apply">Put your car to work</h2><p className="lead muted">{F('Seven questions. We answer within {{ownerReply}} and arrange a call to confirm your fees and registration options. Applying commits you to nothing.')}</p></div>
          <div className="c-6 s-7"><OwnerForm ownersEmail={f.email_aliases.owners ?? s.owners_email ?? undefined} ownerReply={t.ownerReply!} /></div>
        </div>
      </section>
      <section className="section" aria-labelledby="oh-faq">
        <div className="wrap grid"><div className="c-4"><h2 className="d2" id="oh-faq">Owner questions</h2></div><div className="c-8"><Faq items={faq} /></div></div>
      </section>
    </div>
  );
}
